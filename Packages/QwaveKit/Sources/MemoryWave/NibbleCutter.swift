import Foundation

/// Cuts a page into tagged markdown nibbles for wave retrieval.
public enum NibbleCutter {
    public static let maxNibbles = 8
    public static let minCharacters = 48
    public static let maxCharacters = 720

    public static func cut(
        title: String,
        body: String,
        url: URL?,
        kind: MemoryKind,
        containerID: UUID?,
        extraTags: [String] = [],
        at date: Date = Date()
    ) -> [MemoryNibble] {
        let chunks = chunks(from: body, fallbackTitle: title)
        let baseTags = tags(title: title, body: body, url: url, kind: kind) + extraTags
        return chunks.prefix(maxNibbles).enumerated().map { index, chunk in
            let pieceTitle = chunks.count == 1 ? chunk.title : "\(chunk.title) · \(index + 1)"
            var tags = baseTags
            tags.append(contentsOf: NibbleMarkdown.hashtags(in: chunk.body))
            tags.append(contentsOf: headingTags(chunk.title))
            return MemoryNibble(
                title: pieceTitle,
                body: chunk.body,
                tags: tags,
                url: url,
                created: date.addingTimeInterval(TimeInterval(index)),
                kind: kind,
                containerID: containerID
            )
        }
    }

    public static func tags(title: String, body: String, url: URL?, kind: MemoryKind) -> [String] {
        var tags = [kind.rawValue]
        if let host = url?.host {
            tags.append(host)
            let labels = host.split(separator: ".").map(String.init)
            if let head = labels.first, head != "www" { tags.append(head) }
        }
        tags.append(contentsOf: headingTags(title))
        tags.append(contentsOf: NibbleMarkdown.hashtags(in: title + "\n" + body))
        return NibbleMarkdown.normalize(tags: tags)
    }

    private struct Chunk {
        var title: String
        var body: String
    }

    private static func chunks(from body: String, fallbackTitle: String) -> [Chunk] {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return [Chunk(title: fallbackTitle, body: fallbackTitle)]
        }
        let sections = splitHeadings(trimmed, fallbackTitle: fallbackTitle)
        var result: [Chunk] = []
        for section in sections {
            if section.body.count <= maxCharacters {
                if section.body.count >= minCharacters || sections.count == 1 {
                    result.append(section)
                }
            } else {
                result.append(contentsOf: splitParagraphs(section))
            }
        }
        return result.isEmpty ? [Chunk(title: fallbackTitle, body: String(trimmed.prefix(maxCharacters)))] : result
    }

    private static func splitHeadings(_ text: String, fallbackTitle: String) -> [Chunk] {
        let lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init)
        var sections: [Chunk] = []
        var currentTitle = fallbackTitle
        var bucket: [String] = []
        func flush() {
            let body = bucket.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !body.isEmpty {
                sections.append(Chunk(title: currentTitle, body: body))
            }
            bucket = []
        }
        for line in lines {
            if line.hasPrefix("## ") || line.hasPrefix("# ") {
                flush()
                currentTitle = String(line.drop(while: { $0 == "#" || $0 == " " }))
            } else {
                bucket.append(line)
            }
        }
        flush()
        return sections.isEmpty ? [Chunk(title: fallbackTitle, body: text)] : sections
    }

    private static func splitParagraphs(_ section: Chunk) -> [Chunk] {
        let paras = section.body.components(separatedBy: "\n\n").map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }
        var chunks: [Chunk] = []
        var buffer = ""
        for para in paras {
            if buffer.isEmpty {
                buffer = para
            } else if buffer.count + para.count + 2 <= maxCharacters {
                buffer += "\n\n" + para
            } else {
                chunks.append(Chunk(title: section.title, body: buffer))
                buffer = para
            }
        }
        if !buffer.isEmpty {
            chunks.append(Chunk(title: section.title, body: String(buffer.prefix(maxCharacters))))
        }
        return chunks
    }

    private static func headingTags(_ title: String) -> [String] {
        title.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .filter { $0.count >= 4 }
            .prefix(4)
            .compactMap(NibbleMarkdown.normalize)
    }
}
