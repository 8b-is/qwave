import Foundation

public enum LocalDocument: Equatable {
    /// Regular file WebKit can show as-is (html, images, pdf, …).
    case file(URL)
    /// Directory had an index.html — load that file with directory read access.
    case htmlIndex(file: URL, readAccess: URL)
    /// Markdown (or a README without an extension).
    case markdown(source: String, fileURL: URL)
    /// Directory with no index and no README — listing rendered as markdown.
    case listing(markdown: String, directory: URL)
    case missing(URL)
}

/// Resolves `file:` navigations: index.html, then README.md, then a listing.
public enum LocalDocumentResolver {
    public static let indexNames = ["index.html", "index.htm", "Index.html", "INDEX.HTM"]
    public static let readmeNames = [
        "README.md", "readme.md", "Readme.md", "README.markdown", "readme.markdown",
        "README.mdown", "README",
    ]
    public static let markdownExtensions: Set<String> = ["md", "markdown", "mdown", "mdx"]

    public static func isMarkdownURL(_ url: URL) -> Bool {
        markdownExtensions.contains(url.pathExtension.lowercased())
    }

    public static func isMarkdownMIME(_ mime: String?) -> Bool {
        guard let mime else { return false }
        let lower = mime.lowercased()
        return lower == "text/markdown" || lower == "text/x-markdown" || lower.hasPrefix("text/markdown;")
    }

    public static func resolve(_ url: URL, fileManager: FileManager = .default) -> LocalDocument {
        var isDirectory: ObjCBool = false
        let path = url.path
        guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory) else {
            return .missing(url)
        }

        if isDirectory.boolValue {
            return resolveDirectory(url, fileManager: fileManager)
        }

        if isMarkdownURL(url) || url.lastPathComponent.uppercased() == "README" {
            if let source = try? String(contentsOf: url, encoding: .utf8) {
                return .markdown(source: source, fileURL: url)
            }
        }
        return .file(url)
    }

    private static func resolveDirectory(_ directory: URL, fileManager: FileManager) -> LocalDocument {
        for name in indexNames {
            let candidate = directory.appendingPathComponent(name)
            if fileManager.fileExists(atPath: candidate.path) {
                return .htmlIndex(file: candidate, readAccess: directory)
            }
        }
        for name in readmeNames {
            let candidate = directory.appendingPathComponent(name)
            var isDir: ObjCBool = false
            if fileManager.fileExists(atPath: candidate.path, isDirectory: &isDir), !isDir.boolValue,
                let source = try? String(contentsOf: candidate, encoding: .utf8)
            {
                return .markdown(source: source, fileURL: candidate)
            }
        }
        return .listing(markdown: directoryListingMarkdown(directory, fileManager: fileManager), directory: directory)
    }

    public static func directoryListingMarkdown(_ directory: URL, fileManager: FileManager) -> String {
        let name = directory.lastPathComponent.isEmpty ? directory.path : directory.lastPathComponent
        var lines = ["# \(name)", "", "_\(directory.path)_", ""]
        let contents =
            (try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
                options: [.skipsHiddenFiles]
            )) ?? []
        let sorted = contents.sorted {
            $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
        }
        if sorted.isEmpty {
            lines.append("_Empty directory. No index.html, no README.md._")
        }
        for item in sorted {
            let isDir = (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            let label = item.lastPathComponent + (isDir ? "/" : "")
            let href = item.lastPathComponent + (isDir ? "/" : "")
            lines.append("- [\(label)](\(href))")
        }
        return lines.joined(separator: "\n")
    }
}
