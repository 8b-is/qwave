import Foundation
import WebKit

/// A Manifest V3 `declarativeNetRequest` rule specification.
public struct DNRRule: Codable, Equatable, Sendable {
    public var id: Int
    public var priority: Int?
    public var action: Action
    public var condition: Condition

    public struct Action: Codable, Equatable, Sendable {
        public var type: ActionType
        public var redirect: Redirect?

        public enum ActionType: String, Codable, Equatable, Sendable {
            case block = "block"
            case allow = "allow"
            case redirect = "redirect"
        }

        public struct Redirect: Codable, Equatable, Sendable {
            public var url: String?
            public var regexSubstitution: String?

            enum CodingKeys: String, CodingKey {
                case url
                case regexSubstitution = "regex_substitution"
            }

            public init(url: String? = nil, regexSubstitution: String? = nil) {
                self.url = url
                self.regexSubstitution = regexSubstitution
            }
        }

        public init(type: ActionType, redirect: Redirect? = nil) {
            self.type = type
            self.redirect = redirect
        }
    }

    public struct Condition: Codable, Equatable, Sendable {
        public var urlFilter: String?
        public var regexFilter: String?
        public var isUrlFilterCaseSensitive: Bool?
        public var domains: [String]?
        public var excludedDomains: [String]?
        public var resourceTypes: [String]?

        enum CodingKeys: String, CodingKey {
            case urlFilter = "url_filter"
            case regexFilter = "regex_filter"
            case isUrlFilterCaseSensitive = "is_url_filter_case_sensitive"
            case domains
            case excludedDomains = "excluded_domains"
            case resourceTypes = "resource_types"
        }

        public init(
            urlFilter: String? = nil,
            regexFilter: String? = nil,
            isUrlFilterCaseSensitive: Bool? = nil,
            domains: [String]? = nil,
            excludedDomains: [String]? = nil,
            resourceTypes: [String]? = nil
        ) {
            self.urlFilter = urlFilter
            self.regexFilter = regexFilter
            self.isUrlFilterCaseSensitive = isUrlFilterCaseSensitive
            self.domains = domains
            self.excludedDomains = excludedDomains
            self.resourceTypes = resourceTypes
        }
    }

    public init(id: Int, priority: Int? = nil, action: Action, condition: Condition) {
        self.id = id
        self.priority = priority
        self.action = action
        self.condition = condition
    }
}

/// Compiles DNR rules into WebKit `WKContentRuleList` JSON format.
public enum DeclarativeNetRequestConverter {
    /// Converts an array of `DNRRule` into a WebKit content blocker JSON string.
    public static func convertToWebKitRulesJSON(_ rules: [DNRRule]) throws -> String {
        var webKitRules: [[String: Any]] = []

        for rule in rules {
            var trigger: [String: Any] = [:]

            // 1. URL Filter or Regex Filter
            if let regex = rule.condition.regexFilter {
                trigger["url-filter"] = regex
            } else if let urlFilter = rule.condition.urlFilter {
                trigger["url-filter"] = convertUrlFilterToRegex(urlFilter)
            } else {
                trigger["url-filter"] = ".*"
            }

            if let isCaseSensitive = rule.condition.isUrlFilterCaseSensitive {
                trigger["url-filter-is-case-sensitive"] = isCaseSensitive
            }

            if let domains = rule.condition.domains, !domains.isEmpty {
                trigger["if-domain"] = domains
            }

            if let excludedDomains = rule.condition.excludedDomains, !excludedDomains.isEmpty {
                trigger["unless-domain"] = excludedDomains
            }

            if let resourceTypes = rule.condition.resourceTypes, !resourceTypes.isEmpty {
                let mappedTypes = resourceTypes.compactMap { mapResourceType($0) }
                if !mappedTypes.isEmpty {
                    trigger["resource-type"] = mappedTypes
                }
            }

            // 2. Action
            var action: [String: Any] = [:]
            switch rule.action.type {
            case .block:
                action["type"] = "block"
            case .allow:
                action["type"] = "ignore-previous-rules"
            case .redirect:
                action["type"] = "block" // WebKit standard content-blocker fallback
            }

            webKitRules.append([
                "trigger": trigger,
                "action": action
            ])
        }

        let data = try JSONSerialization.data(withJSONObject: webKitRules, options: [.prettyPrinted])
        guard let jsonString = String(data: data, encoding: .utf8) else {
            throw NSError(domain: "DNRConverter", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to encode WebKit JSON"])
        }
        return jsonString
    }

    private static func convertUrlFilterToRegex(_ filter: String) -> String {
        if filter.hasPrefix("||") {
            let hostPart = String(filter.dropFirst(2))
            let escaped = NSRegularExpression.escapedPattern(for: hostPart)
            return "^https?://(?:[^/]+\\.)?" + escaped
        }
        if filter.hasPrefix("|") {
            let rest = String(filter.dropFirst(1))
            return "^" + NSRegularExpression.escapedPattern(for: rest)
        }
        return NSRegularExpression.escapedPattern(for: filter)
    }

    private static func mapResourceType(_ type: String) -> String? {
        switch type.lowercased() {
        case "main_frame": return "document"
        case "sub_frame": return "document"
        case "stylesheet": return "style-sheet"
        case "script": return "script"
        case "image": return "image"
        case "font": return "font"
        case "xmlhttprequest": return "raw"
        case "media": return "media"
        default: return nil
        }
    }
}
