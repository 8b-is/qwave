import Foundation
import Combine
import QwaveSupport

/// High-level VPN facade for the UI: login/logout, relay list, connect with
/// current constraints. Stitches together the API client, key manager,
/// account store, relay selector, and tunnel manager.
@MainActor
public final class MullvadVPNService: ObservableObject {
    @Published public private(set) var relayList: RelayList?
    @Published public var constraints = RelayConstraints()
    @Published public private(set) var isBusy = false
    @Published public private(set) var lastError: String?
    /// Stage B flag; wired through to the tunnel config so the negotiator
    /// seam sees it. No-op with the Stage A noop negotiator.
    @Published public var quantumResistant = true

    public let account: AccountStore
    public let tunnel: TunnelManager

    private let api: MullvadAPIClient
    private let keys: DeviceKeyManager

    public init(
        api: MullvadAPIClient = MullvadAPIClient(),
        secrets: SecretStore,
        defaults: UserDefaults = .standard,
        tunnel: TunnelManager? = nil
    ) {
        self.api = api
        self.keys = DeviceKeyManager(secrets: secrets)
        self.account = AccountStore(secrets: secrets, defaults: defaults)
        self.tunnel = tunnel ?? TunnelManager()
    }

    // MARK: - Session

    public func login(accountNumber: String) async -> Bool {
        isBusy = true
        lastError = nil
        defer { isBusy = false }
        do {
            let token = try await api.obtainAccessToken(accountNumber: accountNumber)
            account.accountNumber = accountNumber
            account.accessToken = token.accessToken
            account.tokenExpiry = token.expiry

            let key = try keys.obtainPrivateKey()
            let device = try await api.registerDevice(
                accessToken: token.accessToken,
                publicKeyBase64: key.publicKey.rawRepresentation.base64EncodedString()
            )
            account.storeDevice(device)

            if let info = try? await api.accountInfo(accessToken: token.accessToken) {
                account.accountExpiry = info.expiry
            }
            QwaveLog.vpn.info("Logged in; device \(device.name, privacy: .public)")
            return true
        } catch {
            lastError = Self.describe(error)
            return false
        }
    }

    public func logout() async {
        isBusy = true
        defer { isBusy = false }
        tunnel.disconnect()
        if let token = account.accessToken, let deviceID = account.deviceID {
            try? await api.deleteDevice(accessToken: token, deviceID: deviceID)
        }
        try? keys.deleteKey()
        account.clear()
    }

    private func ensureAccessToken() async throws -> String {
        if account.hasValidToken, let token = account.accessToken {
            return token
        }
        guard let number = account.accountNumber else {
            throw MullvadAPIError.invalidAccountNumber
        }
        let token = try await api.obtainAccessToken(accountNumber: number)
        account.accessToken = token.accessToken
        account.tokenExpiry = token.expiry
        return token.accessToken
    }

    // MARK: - Relays

    public func loadRelays() async {
        do {
            relayList = try await api.relayList()
        } catch {
            lastError = Self.describe(error)
        }
    }

    public var availableCountries: [(code: String, name: String)] {
        relayList.map(RelaySelector.availableCountries(in:)) ?? []
    }

    // MARK: - Connect

    public func connect() async {
        isBusy = true
        lastError = nil
        defer { isBusy = false }
        do {
            _ = try await ensureAccessToken()

            if relayList == nil {
                await loadRelays()
            }
            guard let relayList else {
                throw MullvadAPIError.invalidResponse
            }
            guard let ipv4 = account.deviceIPv4Address, let ipv6 = account.deviceIPv6Address,
                  let deviceID = account.deviceID, let deviceName = account.deviceName
            else {
                lastError = "Not logged in — add your Mullvad account first."
                return
            }
            guard let selected = RelaySelector.pickRelay(from: relayList, constraints: constraints) else {
                lastError = "No relay matches the current filters."
                return
            }

            let device = MullvadDevice(
                id: deviceID,
                name: deviceName,
                pubkey: (try? keys.publicKeyBase64()) ?? "",
                ipv4Address: ipv4,
                ipv6Address: ipv6
            )
            let config = TunnelSessionConfig.make(
                device: device,
                relayList: relayList,
                selected: selected,
                quantumResistant: quantumResistant
            )
            try await tunnel.connect(with: config)
        } catch {
            lastError = Self.describe(error)
        }
    }

    public func disconnect() {
        tunnel.disconnect()
    }

    private static func describe(_ error: Error) -> String {
        switch error {
        case MullvadAPIError.invalidAccountNumber:
            return "That doesn't look like a Mullvad account number."
        case MullvadAPIError.httpError(let status, _) where status == 401 || status == 403:
            return "Mullvad rejected the account credentials."
        case MullvadAPIError.httpError(let status, _):
            return "Mullvad API error (HTTP \(status))."
        default:
            return (error as NSError).localizedDescription
        }
    }
}
