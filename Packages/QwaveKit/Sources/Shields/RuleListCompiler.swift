import Foundation
import WebKit
import QwaveSupport

public enum RuleListError: Error {
    case missingResource(String)
    case compilationReturnedNothing
}

/// Compiles the bundled content-blocker rule sets into `WKContentRuleList`s.
/// Compiled lists are cached by WebKit keyed on identifier; the identifier
/// embeds a hash of the JSON so editing a shipped list invalidates the cache.
@MainActor
public final class RuleListCompiler {
    public enum BuiltinList: String, CaseIterable, Sendable {
        case adsAndTrackers = "starter-blocklist"
        case httpsUpgrade = "https-upgrade"
    }

    private let store: WKContentRuleListStore
    private var cache: [BuiltinList: WKContentRuleList] = [:]

    public init(store: WKContentRuleListStore? = nil) {
        self.store = store ?? .default()
    }

    public static func builtinJSON(for list: BuiltinList) throws -> String {
        guard let url = Bundle.module.url(forResource: list.rawValue, withExtension: "json") else {
            throw RuleListError.missingResource(list.rawValue)
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    public func compiledList(for list: BuiltinList) async throws -> WKContentRuleList {
        if let cached = cache[list] {
            return cached
        }
        let json = try Self.builtinJSON(for: list)
        let identifier = "\(list.rawValue)-\(Self.stableHash(of: json))"

        if let existing = try? await lookUp(identifier: identifier) {
            cache[list] = existing
            return existing
        }

        let compiled = try await compile(identifier: identifier, json: json)
        cache[list] = compiled
        QwaveLog.shields.info("Compiled rule list \(identifier, privacy: .public)")
        return compiled
    }

    private func lookUp(identifier: String) async throws -> WKContentRuleList? {
        try await withCheckedThrowingContinuation { continuation in
            store.lookUpContentRuleList(forIdentifier: identifier) { list, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: list)
                }
            }
        }
    }

    private func compile(identifier: String, json: String) async throws -> WKContentRuleList {
        try await withCheckedThrowingContinuation { continuation in
            store.compileContentRuleList(forIdentifier: identifier, encodedContentRuleList: json) { list, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let list {
                    continuation.resume(returning: list)
                } else {
                    continuation.resume(throwing: RuleListError.compilationReturnedNothing)
                }
            }
        }
    }

    /// FNV-1a — stable across launches, unlike `String.hashValue`.
    static func stableHash(of string: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return String(hash, radix: 16)
    }
}
