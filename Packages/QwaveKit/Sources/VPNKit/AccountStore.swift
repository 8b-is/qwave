import Foundation
import QwaveSupport

/// Mullvad account state. Secrets (account number, access token) live in the
/// secret store; non-secret metadata in UserDefaults.
public final class AccountStore {
    private enum SecretKey {
        static let accountNumber = "vpn.mullvad.accountNumber"
        static let accessToken = "vpn.mullvad.accessToken"
    }

    private enum DefaultsKey {
        static let deviceID = "qwave.vpn.deviceID"
        static let deviceName = "qwave.vpn.deviceName"
        static let deviceIPv4 = "qwave.vpn.deviceIPv4"
        static let deviceIPv6 = "qwave.vpn.deviceIPv6"
        static let tokenExpiry = "qwave.vpn.tokenExpiry"
        static let accountExpiry = "qwave.vpn.accountExpiry"
    }

    private let secrets: SecretStore
    private let defaults: UserDefaults

    public init(secrets: SecretStore, defaults: UserDefaults = .standard) {
        self.secrets = secrets
        self.defaults = defaults
    }

    public var accountNumber: String? {
        get {
            guard let data = try? secrets.secret(for: SecretKey.accountNumber) else { return nil }
            return String(data: data, encoding: .utf8)
        }
        set {
            if let newValue {
                try? secrets.setSecret(Data(newValue.utf8), for: SecretKey.accountNumber)
            } else {
                try? secrets.removeSecret(for: SecretKey.accountNumber)
            }
        }
    }

    public var accessToken: String? {
        get {
            guard let data = try? secrets.secret(for: SecretKey.accessToken) else { return nil }
            return String(data: data, encoding: .utf8)
        }
        set {
            if let newValue {
                try? secrets.setSecret(Data(newValue.utf8), for: SecretKey.accessToken)
            } else {
                try? secrets.removeSecret(for: SecretKey.accessToken)
            }
        }
    }

    public var tokenExpiry: Date? {
        get { defaults.object(forKey: DefaultsKey.tokenExpiry) as? Date }
        set { defaults.set(newValue, forKey: DefaultsKey.tokenExpiry) }
    }

    public var accountExpiry: Date? {
        get { defaults.object(forKey: DefaultsKey.accountExpiry) as? Date }
        set { defaults.set(newValue, forKey: DefaultsKey.accountExpiry) }
    }

    public var deviceID: String? {
        get { defaults.string(forKey: DefaultsKey.deviceID) }
        set { defaults.set(newValue, forKey: DefaultsKey.deviceID) }
    }

    public var deviceName: String? {
        get { defaults.string(forKey: DefaultsKey.deviceName) }
        set { defaults.set(newValue, forKey: DefaultsKey.deviceName) }
    }

    /// In-tunnel addresses assigned at device registration ("10.67.1.2/32").
    public var deviceIPv4Address: String? {
        get { defaults.string(forKey: DefaultsKey.deviceIPv4) }
        set { defaults.set(newValue, forKey: DefaultsKey.deviceIPv4) }
    }

    public var deviceIPv6Address: String? {
        get { defaults.string(forKey: DefaultsKey.deviceIPv6) }
        set { defaults.set(newValue, forKey: DefaultsKey.deviceIPv6) }
    }

    public func storeDevice(_ device: MullvadDevice) {
        deviceID = device.id
        deviceName = device.name
        deviceIPv4Address = device.ipv4Address
        deviceIPv6Address = device.ipv6Address
    }

    public var isLoggedIn: Bool {
        accountNumber != nil && deviceID != nil
    }

    public var hasValidToken: Bool {
        guard accessToken != nil, let expiry = tokenExpiry else { return false }
        return expiry > Date().addingTimeInterval(60)
    }

    public func clear() {
        accountNumber = nil
        accessToken = nil
        tokenExpiry = nil
        accountExpiry = nil
        deviceID = nil
        deviceName = nil
        deviceIPv4Address = nil
        deviceIPv6Address = nil
    }
}
