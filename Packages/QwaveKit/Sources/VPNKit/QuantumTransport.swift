import Foundation

/// The in-tunnel quantum key exchange transport (docs/VPN_STAGE_B.md).
///
/// Mullvad's quantum-resistant tunnels negotiate the preshared key *inside*
/// the established classic tunnel against a relay-side ephemeral-peer
/// service. This seam carries the KEM material between the negotiator and
/// that service; the concrete `MullvadEphemeralPeerTransport` speaks a
/// versioned JSON protocol to the relay's in-tunnel endpoint (the gRPC
/// service in mullvadvpn-app, port 1337, is JSON-encodable in the same
/// shape). The transport is injectable so unit tests can simulate a relay.
public protocol QuantumTransporting: Sendable {
    /// Sends the client's post-quantum encapsulation keys to the relay and
    /// returns the relay's ciphertext bundle.
    func requestEphemeralPeer(_ request: EphemeralPeerRequest) async throws -> EphemeralPeerResponse
}

/// Client -> relay: the WG public key plus the KEM encapsulation key.
public struct EphemeralPeerRequest: Codable, Equatable, Sendable {
    /// WireGuard public key of the session (base64).
    public var wgPublicKey: String
    /// ML-KEM-768 encapsulation key (base64).
    public var mlkemPublicKey: String
    /// Relay hostname, for the service's routing.
    public var relayHostname: String

    public init(
        wgPublicKey: String,
        mlkemPublicKey: String,
        relayHostname: String
    ) {
        self.wgPublicKey = wgPublicKey
        self.mlkemPublicKey = mlkemPublicKey
        self.relayHostname = relayHostname
    }

    enum CodingKeys: String, CodingKey {
        case wgPublicKey = "wg_public_key"
        case mlkemPublicKey = "mlkem_public_key"
        case relayHostname = "relay_hostname"
    }
}

/// Relay -> client: the ciphertext the PSK is decapsulated from.
public struct EphemeralPeerResponse: Codable, Equatable, Sendable {
    /// ML-KEM-768 ciphertext (base64, 1088 bytes). Kept as a "bundle" field
    /// so the wire format survives a parameter change.
    public var ciphertextBundle: String

    public init(ciphertextBundle: String) {
        self.ciphertextBundle = ciphertextBundle
    }

    enum CodingKeys: String, CodingKey {
        case ciphertextBundle = "ciphertext"
    }
}

public enum QuantumTransportError: Error {
    case invalidResponse
    case transportFailed(underlying: Error)
}

/// Default transport: JSON over the in-tunnel gateway (port 1337), matching
/// the documented ephemeral-peer service location. On development builds
/// without a signed tunnel this fails fast and the negotiator's caller
/// falls back to classic WireGuard.
public struct MullvadEphemeralPeerTransport: QuantumTransporting {
    public var endpoint: URL
    public var session: URLSession

    public init(endpoint: URL? = nil, session: URLSession = .shared) {
        // The in-tunnel gateway DNS name resolves only inside the tunnel;
        // the endpoint is replaced by the relay's assigned gateway address
        // when the app has one (see TunnelSessionConfig.dnsServers).
        self.endpoint = endpoint ?? URL(string: "http://10.64.0.1:1337/qwave/ephemeral-peer")!
        self.session = session
    }

    public func requestEphemeralPeer(_ request: EphemeralPeerRequest) async throws -> EphemeralPeerResponse {
        var urlRequest = URLRequest(url: endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        urlRequest.httpBody = try JSONEncoder().encode(request)
        urlRequest.timeoutInterval = 10

        do {
            let (data, response) = try await session.data(for: urlRequest)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                throw QuantumTransportError.invalidResponse
            }
            return try JSONDecoder().decode(EphemeralPeerResponse.self, from: data)
        } catch let error as QuantumTransportError {
            throw error
        } catch {
            throw QuantumTransportError.transportFailed(underlying: error)
        }
    }
}
