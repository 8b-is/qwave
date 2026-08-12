import Foundation

/// One WebKit runtime feature discovered via SPI reflection.
public struct WebFeature: Identifiable, Equatable {
    /// WebKit's internal status buckets. Raw values track `_WKFeatureStatus`;
    /// unknown numbers degrade to `.unknown` rather than failing.
    public enum Status: Equatable {
        case embedder
        case unstable
        case internalDebug
        case developer
        case testable
        case preview
        case stable
        case shipping
        case unknown(Int)

        public init(rawStatus: Int) {
            switch rawStatus {
            case 0: self = .embedder
            case 1: self = .unstable
            case 2: self = .internalDebug
            case 3: self = .developer
            case 4: self = .testable
            case 5: self = .preview
            case 6: self = .stable
            case 7: self = .shipping
            default: self = .unknown(rawStatus)
            }
        }

        public var displayName: String {
            switch self {
            case .embedder: return "Embedder"
            case .unstable: return "Unstable"
            case .internalDebug: return "Internal"
            case .developer: return "Developer"
            case .testable: return "Testable"
            case .preview: return "Preview"
            case .stable: return "Stable"
            case .shipping: return "Shipping"
            case .unknown(let raw): return "Status \(raw)"
            }
        }

        /// Buckets surfaced in the settings pane by default. Embedder and
        /// internal-debug flags are hidden unless the user opts in.
        public var isUserFacing: Bool {
            switch self {
            case .testable, .preview, .stable, .shipping, .developer, .unstable:
                return true
            case .embedder, .internalDebug, .unknown:
                return false
            }
        }
    }

    public let key: String
    public let name: String
    public let details: String?
    public let status: Status
    public let defaultValue: Bool
    public var isEnabled: Bool

    public var id: String { key }

    public init(key: String, name: String, details: String?, status: Status, defaultValue: Bool, isEnabled: Bool) {
        self.key = key
        self.name = name
        self.details = details
        self.status = status
        self.defaultValue = defaultValue
        self.isEnabled = isEnabled
    }
}
