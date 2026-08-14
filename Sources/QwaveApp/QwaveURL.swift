import Foundation

/// `qwave://` URL scheme: lets any app, Terminal, or Shortcuts tell Qwave to
/// open a page — `open "qwave://example.com/path"` or
/// `qwave://https://example.com`. The scheme carries only the destination and
/// accepts nothing but http(s) targets, so it cannot reach internal pages,
/// files, or other schemes.
enum QwaveURL {
    static let scheme = "qwave"

    enum Action: Equatable {
        case open(URL)
    }

    /// Maps a `qwave://` URL to an action, or nil if it isn't one or the
    /// target isn't http(s).
    static func parse(_ url: URL) -> Action? {
        guard url.scheme?.lowercased() == scheme else { return nil }
        let rest = url.absoluteString.dropFirst(scheme.count + 3)  // "qwave://"
        guard !rest.isEmpty else { return nil }
        let lowered = rest.lowercased()
        let target: URL?
        if lowered.hasPrefix("http://") || lowered.hasPrefix("https://") {
            target = URL(string: String(rest))
        } else {
            target = URL(string: "https://" + rest)
        }
        guard let target, let targetScheme = target.scheme?.lowercased(),
            targetScheme == "http" || targetScheme == "https"
        else { return nil }
        return .open(target)
    }
}
