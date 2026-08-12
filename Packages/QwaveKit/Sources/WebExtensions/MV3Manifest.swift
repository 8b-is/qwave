import Foundation

/// Manifest V3 extension manifest (the subset Qwave supports).
public struct MV3Manifest: Codable, Equatable, Sendable {
    public var name: String
    public var version: String
    public var manifestVersion: Int
    /// `action.default_popup` — the popup HTML path (browser_action legacy
    /// also accepted).
    public var popupPath: String?
    public var permissions: [String]
    public var contentScripts: [ContentScript]

    public struct ContentScript: Codable, Equatable, Sendable {
        public var matches: [String]
        public var js: [String]
        public var runAt: String?
    }

    enum CodingKeys: String, CodingKey {
        case name, version, permissions
        case manifestVersion = "manifest_version"
        case action
        case browserAction = "browser_action"
        case contentScripts = "content_scripts"
    }

    public struct Action: Codable, Equatable, Sendable {
        public var defaultPopup: String?

        enum CodingKeys: String, CodingKey {
            case defaultPopup = "default_popup"
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        version = try container.decode(String.self, forKey: .version)
        manifestVersion = try container.decodeIfPresent(Int.self, forKey: .manifestVersion) ?? 2
        permissions = try container.decodeIfPresent([String].self, forKey: .permissions) ?? []
        contentScripts = try container.decodeIfPresent([ContentScript].self, forKey: .contentScripts) ?? []
        if let action = try container.decodeIfPresent(Action.self, forKey: .action) {
            popupPath = action.defaultPopup
        } else if let legacy = try container.decodeIfPresent(Action.self, forKey: .browserAction) {
            popupPath = legacy.defaultPopup
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(version, forKey: .version)
        try container.encode(manifestVersion, forKey: .manifestVersion)
        try container.encode(permissions, forKey: .permissions)
        try container.encode(contentScripts, forKey: .contentScripts)
        if let popupPath {
            try container.encode(Action(defaultPopup: popupPath), forKey: .action)
        }
    }

    public init(
        name: String,
        version: String,
        manifestVersion: Int = 3,
        popupPath: String? = nil,
        permissions: [String] = [],
        contentScripts: [ContentScript] = []
    ) {
        self.name = name
        self.version = version
        self.manifestVersion = manifestVersion
        self.popupPath = popupPath
        self.permissions = permissions
        self.contentScripts = contentScripts
    }
}
