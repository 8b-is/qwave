import Foundation
import WebURL
import WebURLFoundationExtras

public enum OmniboxInput: Equatable {
    case url(URL)
    case search(String)
}

/// URL-vs-search heuristic for the omnibox. Pure logic, exhaustively tested.
public enum OmniboxParser {
    public static func parse(_ raw: String) -> OmniboxInput {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .search("") }

        // Explicit scheme wins outright.
        let lower = trimmed.lowercased()
        for scheme in ["http://", "https://", "file://", "about:"] {
            if lower.hasPrefix(scheme) {
                return url(from: trimmed) ?? .search(trimmed)
            }
        }

        // Anything with whitespace is a query.
        if trimmed.contains(where: { $0 == " " || $0 == "\t" }) {
            return .search(trimmed)
        }

        // Split off path/query to inspect the authority alone.
        let authority = trimmed.split(separator: "/", maxSplits: 1)[0]
        let hostPart = authority.split(separator: ":", maxSplits: 1)[0].lowercased()
        let portPart =
            authority.contains(":")
            ? authority.split(separator: ":", maxSplits: 1).last.map(String.init)
            : nil

        // Port must be numeric for this to be host:port and not e.g. "note:text".
        if let portPart, UInt16(portPart) == nil {
            return .search(trimmed)
        }

        let looksLikeHost: Bool
        if hostPart == "localhost" {
            looksLikeHost = true
        } else if isIPv4(String(hostPart)) {
            looksLikeHost = true
        } else if hostPart.contains(".") && !hostPart.hasPrefix(".") && !hostPart.hasSuffix(".") {
            // Needs a plausible TLD: last label ≥ 2 chars, alphabetic-or-punycode.
            let labels = hostPart.split(separator: ".", omittingEmptySubsequences: false)
            if let last = labels.last, labels.allSatisfy({ !$0.isEmpty }),
                last.count >= 2,
                last.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" }),
                last.contains(where: { $0.isLetter })
            {
                looksLikeHost = true
            } else {
                looksLikeHost = false
            }
        } else {
            looksLikeHost = false
        }

        guard looksLikeHost else {
            return .search(trimmed)
        }

        return url(from: "https://\(trimmed)") ?? .search(trimmed)
    }

    /// Builds the returned URL through the WHATWG parser, so the identity we
    /// hand out is the identity WebKit will load. When Foundation and WHATWG
    /// agree on the host (the common ASCII case), Foundation's serialization
    /// of the raw input is kept; when they disagree (IDN, percent-encoded or
    /// non-decimal-IP hosts, multiple-@ authorities) the canonical WHATWG
    /// serialization wins. Inputs the WHATWG parser rejects become searches.
    private static func url(from string: String) -> OmniboxInput? {
        guard let webURL = WebURL(string) else { return nil }
        let canonicalHost = webURL.host?.serialized ?? ""
        if let foundation = URL(string: string),
            (foundation.host ?? "").lowercased() == canonicalHost
        {
            return .url(foundation)
        }
        guard let converted = URL(webURL) else { return nil }
        return .url(converted)
    }

    private static func isIPv4(_ candidate: String) -> Bool {
        let parts = candidate.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts.allSatisfy { UInt8($0) != nil }
    }
}
