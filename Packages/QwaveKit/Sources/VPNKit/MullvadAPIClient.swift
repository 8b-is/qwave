import Foundation
import QwaveSupport

public enum MullvadAPIError: Error, Equatable {
    case invalidResponse
    case httpError(status: Int, message: String?)
    case invalidAccountNumber
}

/// Async REST client for api.mullvad.net. Transport is a plain URLSession so
/// tests inject a `URLProtocol` mock; no live network is touched in CI.
///
/// Endpoint paths mirror the open-source mullvadvpn-app:
///  - POST /auth/v1/token            account number → bearer token
///  - GET  /accounts/v1/accounts/me  account info (expiry)
///  - POST /accounts/v1/devices      register WireGuard pubkey → device + addresses
///  - GET  /accounts/v1/devices      list devices
///  - DELETE /accounts/v1/devices/:id
///  - GET  /app/v1/relays            relay list
public struct MullvadAPIClient: Sendable {
    public let baseURL: URL
    private let session: URLSession

    public init(session: URLSession = .shared, baseURL: URL = URL(string: "https://api.mullvad.net")!) {
        self.session = session
        self.baseURL = baseURL
    }

    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let string = try container.decode(String.self)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: string) {
                return date
            }
            formatter.formatOptions = [.withInternetDateTime]
            if let date = formatter.date(from: string) {
                return date
            }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unparseable date \(string)")
        }
        return decoder
    }

    // MARK: - Requests

    private func request(
        path: String,
        method: String,
        accessToken: String? = nil,
        body: [String: Any]? = nil
    ) async throws -> Data {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let accessToken {
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw MullvadAPIError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let message = String(data: data, encoding: .utf8)
            QwaveLog.vpn.error("Mullvad API \(path, privacy: .public) → \(http.statusCode)")
            throw MullvadAPIError.httpError(status: http.statusCode, message: message)
        }
        return data
    }

    // MARK: - Auth

    public func obtainAccessToken(accountNumber: String) async throws -> MullvadAccessToken {
        let trimmed = accountNumber.replacingOccurrences(of: " ", with: "")
        guard !trimmed.isEmpty, trimmed.allSatisfy(\.isNumber) else {
            throw MullvadAPIError.invalidAccountNumber
        }
        let data = try await request(
            path: "auth/v1/token",
            method: "POST",
            body: ["account_number": trimmed]
        )
        return try Self.decoder().decode(MullvadAccessToken.self, from: data)
    }

    public func accountInfo(accessToken: String) async throws -> MullvadAccount {
        let data = try await request(path: "accounts/v1/accounts/me", method: "GET", accessToken: accessToken)
        return try Self.decoder().decode(MullvadAccount.self, from: data)
    }

    // MARK: - Devices

    public func registerDevice(accessToken: String, publicKeyBase64: String) async throws -> MullvadDevice {
        let data = try await request(
            path: "accounts/v1/devices",
            method: "POST",
            accessToken: accessToken,
            body: ["pubkey": publicKeyBase64, "hijack_dns": false]
        )
        return try Self.decoder().decode(MullvadDevice.self, from: data)
    }

    public func devices(accessToken: String) async throws -> [MullvadDevice] {
        let data = try await request(path: "accounts/v1/devices", method: "GET", accessToken: accessToken)
        return try Self.decoder().decode([MullvadDevice].self, from: data)
    }

    public func deleteDevice(accessToken: String, deviceID: String) async throws {
        _ = try await request(path: "accounts/v1/devices/\(deviceID)", method: "DELETE", accessToken: accessToken)
    }

    // MARK: - Relays

    public func relayList() async throws -> RelayList {
        let data = try await request(path: "app/v1/relays", method: "GET")
        return try Self.decoder().decode(RelayList.self, from: data)
    }
}
