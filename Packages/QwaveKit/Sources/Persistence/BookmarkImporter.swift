import Foundation

/// A bookmark parsed from another browser's export, flattened to the fields
/// Qwave stores. The enclosing folder is the nearest named folder, or the root
/// name ("Bookmark bar", "Other") for top-level entries.
public struct ImportedBookmark: Equatable, Sendable {
    public let title: String
    public let url: URL
    public let folder: String?

    public init(title: String, url: URL, folder: String?) {
        self.title = title
        self.url = url
        self.folder = folder
    }
}

public enum BookmarkImportError: Error, Equatable {
    case malformed
}

/// Parses bookmark exports from other browsers. Pure and synchronous so it is
/// unit-testable without disk or SQLite access; the file-picking UI (an
/// NSOpenPanel with a security-scoped read) lives in the app target.
public enum BookmarkImporter {
    /// Parses a Chromium "Bookmarks" file (Chrome, Edge, Brave, Vivaldi).
    ///
    /// The format is a JSON tree under `roots`, each node either a `url`
    /// (`name` + `url`) or a `folder` (`name` + `children`). Only http/https
    /// bookmarks are kept, matching what Qwave can open — bookmarklets and
    /// internal chrome:// entries are dropped.
    public static func parseChromiumJSON(_ data: Data) throws -> [ImportedBookmark] {
        guard
            let object = try? JSONSerialization.jsonObject(with: data),
            let root = object as? [String: Any],
            let roots = root["roots"] as? [String: Any]
        else {
            throw BookmarkImportError.malformed
        }

        var result: [ImportedBookmark] = []
        // Deterministic order: the standard roots first, then any others.
        let preferred = ["bookmark_bar", "other", "synced"]
        let extras = roots.keys.filter { !preferred.contains($0) }.sorted()
        for key in preferred.filter({ roots[$0] != nil }) + extras {
            guard let node = roots[key] as? [String: Any] else { continue }
            walk(node, folder: node["name"] as? String, into: &result)
        }
        return result
    }

    private static func walk(_ node: [String: Any], folder: String?, into result: inout [ImportedBookmark]) {
        if node["type"] as? String == "url",
            let urlString = node["url"] as? String,
            let url = URL(string: urlString),
            let scheme = url.scheme?.lowercased(),
            scheme == "http" || scheme == "https"
        {
            let title = (node["name"] as? String) ?? url.absoluteString
            result.append(ImportedBookmark(title: title, url: url, folder: folder))
            return
        }
        if let children = node["children"] as? [[String: Any]] {
            let childFolder = (node["name"] as? String) ?? folder
            for child in children {
                walk(child, folder: childFolder, into: &result)
            }
        }
    }
}
