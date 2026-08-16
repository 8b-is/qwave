import Foundation

/// How much of a markdown source document the compiler is allowed to trust.
///
/// The distinction is about the *origin the rendered HTML ends up in*, not
/// about the document's content. `NavigationCoordinator.presentMarkdown` calls
/// `loadHTMLString(html, baseURL: url)`, so the compiled page inherits `url`'s
/// origin — and the two callers hand it very different URLs.
public enum MarkdownTrust: Sendable {
    /// CommonMark behaviour: raw HTML in the source reaches the page.
    ///
    /// Correct for a document fetched over http(s): it renders with `baseURL`
    /// set to its own remote URL, so any script in it runs as *that site's*
    /// origin. The site could have served the same script by returning HTML
    /// instead of markdown, so passing raw HTML through grants nothing new,
    /// and inline HTML is conformant CommonMark that authors rely on.
    case rawHTMLAllowed

    /// Only markup this compiler itself emitted survives; every `<` in the
    /// source becomes text.
    ///
    /// Correct for a `file://` document. There `baseURL` is the file's own
    /// `file://` URL, so script in a downloaded `.md` executes in the
    /// `file://` origin — an origin the user shares with every other local
    /// document — and a text file the user opened to *read* should not run
    /// code. Measured blast radius, on this configuration: reading sibling
    /// files is blocked (`allowFileAccessFromFileURLs` and
    /// `allowUniversalAccessFromFileURLs` are both false — see
    /// `FileOriginCapabilityTests`), but `file://` `localStorage` is shared
    /// across all local documents and outbound no-cors requests do leave the
    /// machine.
    case compilerOutputOnly
}

/// Small CommonMark-ish compiler: headings, lists, tables, fences, quotes,
/// task items, links, images, emphasis, and math/mermaid placeholders.
/// Mermaid and KaTeX are applied in the page by bundled scripts; this pass
/// only emits the HTML they look for. Works with JavaScript off.
///
/// Every emitted inline fragment is *parked* — swapped for an opaque marker
/// and spliced back after all escaping has run. That is what makes the two
/// `MarkdownTrust` levels a one-line difference (which escaper runs over the
/// leftover source text) instead of a tag-shape allowlist that source text
/// could imitate: under `.compilerOutputOnly` the markup that survives is, by
/// construction, exactly the markup this file produced.
///
/// "By construction" rests on the marker being unmintable from source text,
/// which in turn rests on `compile` stripping U+0000 first. See `sanitizeNULs`.
public enum MarkdownCompiler {
    /// - Parameter trust: what the *caller* knows about where this document
    ///   came from. Deliberately has no default: the two call sites in
    ///   `NavigationCoordinator` need opposite answers, and a wrong default is
    ///   invisible at the call site.
    public static func compile(_ source: String, trust: MarkdownTrust) -> String {
        // One scan for both bytes that have to be rewritten before anything
        // else reads the text. Neither is present in a real document, so the
        // common path allocates nothing; the old code scanned for CR alone and
        // this keeps that shape.
        var hasCR = false
        var hasNUL = false
        for byte in source.utf8 {
            if byte == 0x0D {
                hasCR = true
                if hasNUL { break }
            } else if byte == 0x00 {
                hasNUL = true
                if hasCR { break }
            }
        }
        // Both replacements are no-op whole-string copies unless the byte is
        // present, and almost no document has either.
        var normalized = source
        if hasCR {
            normalized = normalized.replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\r", with: "\n")
        }
        if hasNUL {
            normalized = sanitizeNULs(normalized)
        }
        var store: [String] = []
        func park(_ html: String) -> String {
            store.append(html)
            return "\u{0000}MD\(store.count - 1)\u{0000}"
        }

        var text = extractFences(normalized, park: park)
        text = extractDisplayMath(text, park: park)
        let blocks = splitBlocks(text)
        var html: [String] = []
        html.reserveCapacity(blocks.count)
        for block in blocks {
            html.append(renderBlock(block, trust: trust, park: park))
        }
        var joined = html.joined(separator: "\n")
        // Reversed order so nested parks resolve: an outer park's value can
        // contain a marker for an inner park (math block wrapping a fence).
        for (index, value) in store.enumerated().reversed() {
            joined = joined.replacingOccurrences(of: "\u{0000}MD\(index)\u{0000}", with: value)
        }
        return joined
    }

    // MARK: - Extractors

    private static func extractFences(_ source: String, park: (String) -> String) -> String {
        var result = ""
        var remainder = source[...]
        while let start = remainder.range(of: "```") {
            result += remainder[..<start.lowerBound]
            let afterTicks = remainder[start.upperBound...]
            let langEnd = afterTicks.firstIndex(of: "\n") ?? afterTicks.endIndex
            let lang = afterTicks[..<langEnd].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let bodyStart = langEnd == afterTicks.endIndex ? afterTicks.endIndex : afterTicks.index(after: langEnd)
            let rest = afterTicks[bodyStart...]
            if let end = rest.range(of: "```") {
                let body = String(rest[..<end.lowerBound]).trimmingCharacters(in: .newlines)
                if lang == "mermaid" {
                    result += park("<pre class=\"mermaid\">\(escape(body))</pre>")
                } else {
                    let cls = lang.isEmpty ? "" : " class=\"language-\(escape(lang))\""
                    result += park("<pre><code\(cls)>\(escape(body))\n</code></pre>")
                }
                remainder = rest[end.upperBound...]
                if remainder.first == "\n" {
                    remainder = remainder.dropFirst()
                }
            } else {
                result += "```"
                remainder = afterTicks
            }
        }
        result += remainder
        return result
    }

    private static func extractDisplayMath(_ source: String, park: (String) -> String) -> String {
        var result = ""
        var remainder = source[...]
        while let start = remainder.range(of: "$$") {
            result += remainder[..<start.lowerBound]
            let rest = remainder[start.upperBound...]
            if let end = rest.range(of: "$$") {
                let body = String(rest[..<end.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                result += park("<div class=\"math-display\">\(escape(body))</div>")
                remainder = rest[end.upperBound...]
            } else {
                result += "$$"
                remainder = rest
            }
        }
        result += remainder
        return result
    }

    private static func splitBlocks(_ source: String) -> [String] {
        let lines = source.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        var blocks: [String] = []
        var current: [Substring] = []

        func flush() {
            // `current` only ever holds lines that failed the blank test, and
            // `split(whereSeparator: \.isNewline)` guarantees no line contains a
            // newline character. So the joined text can neither begin nor end
            // with a newline, nor be all-whitespace: both trims the old code ran
            // here were no-ops that allocated a whole copy each.
            guard !current.isEmpty else { return }
            blocks.append(current.joined(separator: "\n"))
            current = []
        }

        func kind(_ t: String) -> String {
            if t.hasPrefix("#") { return "heading" }
            if t.hasPrefix(">") { return "quote" }
            if t == "---" || t == "***" || t == "___" { return "hr" }
            if t.hasPrefix("- ") || t.hasPrefix("* ") || t.hasPrefix("+ ") { return "ul" }
            if t.range(of: #"^\d+\. "#, options: .regularExpression) != nil { return "ol" }
            if t.contains("|") { return "table" }
            return "p"
        }

        var lastKind = ""
        for line in lines {
            // Trim once and hand the result to `kind`; the old code trimmed the
            // same line twice, allocating a String each time.
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                flush()
                lastKind = ""
                continue
            }
            let next = kind(trimmed)
            if !current.isEmpty, next != lastKind, next != "p" || lastKind != "p" {
                flush()
            }
            current.append(line)
            lastKind = next
        }
        flush()
        return blocks
    }

    // MARK: - Blocks

    private static func renderBlock(_ block: String, trust: MarkdownTrust, park: (String) -> String) -> String {
        let trimmed = block.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("\u{0000}MD") { return trimmed }

        if trimmed.hasPrefix("### ") {
            return "<h3>\(inline(String(trimmed.dropFirst(4)), trust: trust, park: park))</h3>"
        }
        if trimmed.hasPrefix("## ") {
            return "<h2>\(inline(String(trimmed.dropFirst(3)), trust: trust, park: park))</h2>"
        }
        if trimmed.hasPrefix("# ") {
            return "<h1>\(inline(String(trimmed.dropFirst(2)), trust: trust, park: park))</h1>"
        }
        if trimmed == "---" || trimmed == "***" || trimmed == "___" {
            return "<hr>"
        }
        if trimmed.hasPrefix("> ") || trimmed.hasPrefix(">") {
            let quoted = trimmed.split(whereSeparator: \.isNewline).map { line -> String in
                var s = String(line)
                if s.hasPrefix("> ") { s.removeFirst(2) } else if s.hasPrefix(">") { s.removeFirst() }
                return s
            }.joined(separator: "\n")
            return "<blockquote>\(renderBlock(quoted, trust: trust, park: park))</blockquote>"
        }
        if isTable(trimmed) {
            return renderTable(trimmed, trust: trust, park: park)
        }
        if isList(trimmed) {
            return renderList(trimmed, trust: trust, park: park)
        }
        let paragraphs = trimmed.split(separator: "\n")
            .map { inline(String($0), trust: trust, park: park) }
            .joined(separator: "<br>")
        return "<p>\(paragraphs)</p>"
    }

    private static func isList(_ block: String) -> Bool {
        let first = block.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        return first.hasPrefix("- ") || first.hasPrefix("* ") || first.hasPrefix("+ ")
            || first.range(of: #"^\d+\. "#, options: .regularExpression) != nil
    }

    private static func renderList(_ block: String, trust: MarkdownTrust, park: (String) -> String) -> String {
        let lines = block.split(whereSeparator: \.isNewline).map(String.init)
        let ordered = lines.first?.range(of: #"^\d+\. "#, options: .regularExpression) != nil
        let tag = ordered ? "ol" : "ul"
        let items = lines.map { line -> String in
            var body = line
            if body.hasPrefix("- ") || body.hasPrefix("* ") || body.hasPrefix("+ ") {
                body = String(body.dropFirst(2))
            } else if let range = body.range(of: #"^\d+\. "#, options: .regularExpression) {
                body = String(body[range.upperBound...])
            }
            if body.hasPrefix("[ ] ") {
                let text = inline(String(body.dropFirst(4)), trust: trust, park: park)
                return "<li class=\"task\"><input type=\"checkbox\" disabled> \(text)</li>"
            }
            if body.hasPrefix("[x] ") || body.hasPrefix("[X] ") {
                let text = inline(String(body.dropFirst(4)), trust: trust, park: park)
                return "<li class=\"task\"><input type=\"checkbox\" disabled checked> \(text)</li>"
            }
            return "<li>\(inline(body, trust: trust, park: park))</li>"
        }
        return "<\(tag)>\(items.joined())</\(tag)>"
    }

    private static func isTable(_ block: String) -> Bool {
        let lines = block.split(whereSeparator: \.isNewline).map(String.init)
        guard lines.count >= 2, lines[0].contains("|"), lines[1].contains("|") else { return false }
        let sep = lines[1].trimmingCharacters(in: .whitespaces)
        return sep.contains("-") && sep.filter { $0 == "-" || $0 == "|" || $0 == ":" || $0 == " " }.count == sep.count
    }

    private static func renderTable(_ block: String, trust: MarkdownTrust, park: (String) -> String) -> String {
        let lines = block.split(whereSeparator: \.isNewline).map(String.init)
        func cells(_ line: String) -> [String] {
            var s = line.trimmingCharacters(in: .whitespaces)
            if s.hasPrefix("|") { s.removeFirst() }
            if s.hasSuffix("|") { s.removeLast() }
            return s.split(separator: "|", omittingEmptySubsequences: false).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
        }
        let header = cells(lines[0])
        let body = lines.dropFirst(2).map(cells)
        var html = "<table><thead><tr>"
        html += header.map { "<th>\(inline($0, trust: trust, park: park))</th>" }.joined()
        html += "</tr></thead><tbody>"
        for row in body {
            html += "<tr>"
            html += row.map { "<td>\(inline($0, trust: trust, park: park))</td>" }.joined()
            html += "</tr>"
        }
        html += "</tbody></table>"
        return html
    }

    // MARK: - Inline

    /// Compiled once per process, not per call. `inline()` runs eight regex
    /// passes per invocation; the old code recompiled every pattern on every
    /// pass. NSRegularExpression is documented thread-safe.
    private final class RegexBox: @unchecked Sendable {
        let value: NSRegularExpression
        init(_ pattern: String) {
            value = try! NSRegularExpression(pattern: pattern)
        }
    }

    private static let imageRegex = RegexBox(#"!\[([^\]]*)\]\(([^)]+)\)"#)
    private static let linkRegex = RegexBox(#"\[([^\]]+)\]\(([^)]+)\)"#)
    private static let mathRegex = RegexBox(#"(?<!\$)\$(?!\$)([^$\n]+)\$(?!\$)"#)
    private static let codeRegex = RegexBox(#"`([^`]+)`"#)
    private static let strongStarRegex = RegexBox(#"\*\*([^*]+)\*\*"#)
    private static let strongUnderscoreRegex = RegexBox(#"__([^_]+)__"#)
    private static let emRegex = RegexBox(#"(?<!\*)\*([^*]+)\*(?!\*)"#)
    private static let delRegex = RegexBox(#"~~([^~]+)~~"#)

    /// Zero-allocation UTF-8 scan for a single ASCII byte.
    ///
    /// Every inline pattern below needs a specific ASCII byte to match at all,
    /// so this is a *necessary* condition: when the byte is absent the regex
    /// provably cannot match and skipping the pass is byte-identical to running
    /// it. Running the pass unconditionally cost ~4 allocations even with zero
    /// matches (NSString bridge, output buffer, tail substring, bridge back),
    /// eight times per line.
    private static func contains(_ text: String, _ byte: UInt8) -> Bool {
        for candidate in text.utf8 where candidate == byte { return true }
        return false
    }

    /// Compiles one line of inline markdown.
    ///
    /// Every fragment emitted below is handed to `park`, so what the eight
    /// passes leave behind is source text and opaque markers — never HTML.
    /// Two bugs fall out of that:
    ///
    /// - The escaper at the end can no longer re-escape a fragment that was
    ///   already escaped. `` `<script>` `` used to compile to
    ///   `<code>&amp;lt;script&amp;gt;</code>` (issue #131's "related, same
    ///   file"), because `escapeLoose` walked back over the `&` in the `&lt;`
    ///   this function had just written. Now it emits `<code>&lt;script&gt;</code>`.
    /// - Under `.compilerOutputOnly` the leftover text can be escaped
    ///   wholesale with `escape`, because nothing that must survive is still
    ///   inline. That is the sanitiser: an allowlist by construction, with no
    ///   tag names in it to get wrong.
    private static func inline(_ raw: String, trust: MarkdownTrust, park: (String) -> String) -> String {
        var text = raw
        // Images then links.
        if contains(text, 0x21), contains(text, 0x5B) {  // "!" and "["
            text = replace(text, regex: imageRegex) { match in
                park(imageTag(source: match[2], alt: match[1], trust: trust))
            }
        }
        if contains(text, 0x5B) {  // "["
            text = replace(text, regex: linkRegex) { match in
                park(anchorTag(href: match[2], label: match[1], trust: trust))
            }
        }
        // Inline math $...$ (not $$)
        if contains(text, 0x24) {  // "$"
            text = replace(text, regex: mathRegex) { match in
                park("<span class=\"math-inline\">\(escape(match[1]))</span>")
            }
        }
        if contains(text, 0x60) {  // "`"
            text = replace(text, regex: codeRegex) { match in
                park("<code>\(escape(match[1]))</code>")
            }
        }
        if contains(text, 0x2A) {  // "*"
            text = replace(text, regex: strongStarRegex) { match in
                park("<strong>\(escape(match[1]))</strong>")
            }
        }
        if contains(text, 0x5F) {  // "_"
            text = replace(text, regex: strongUnderscoreRegex) { match in
                park("<strong>\(escape(match[1]))</strong>")
            }
        }
        if contains(text, 0x2A) {  // "*"
            text = replace(text, regex: emRegex) { match in
                park("<em>\(escape(match[1]))</em>")
            }
        }
        if contains(text, 0x7E) {  // "~"
            text = replace(text, regex: delRegex) { match in
                park("<del>\(escape(match[1]))</del>")
            }
        }
        // Whatever is left is source text, not compiler output.
        switch trust {
        case .rawHTMLAllowed: return escapeLoose(text)
        case .compilerOutputOnly: return escape(text)
        }
    }

    /// `<a>` for `[label](href)`.
    ///
    /// Under `.compilerOutputOnly` an href that would *execute* rather than
    /// navigate loses its target: the compiler emitting the anchor is not a
    /// reason to trust a URL that came out of the source document. The anchor
    /// itself stays so the label still renders in place.
    private static func anchorTag(href: String, label: String, trust: MarkdownTrust) -> String {
        if trust == .compilerOutputOnly, isExecutableURL(href) {
            return "<a>\(escape(label))</a>"
        }
        return "<a href=\"\(escape(href))\">\(escape(label))</a>"
    }

    /// `<img>` for `![alt](source)`, with the same rule for the source URL.
    private static func imageTag(source: String, alt: String, trust: MarkdownTrust) -> String {
        if trust == .compilerOutputOnly, isExecutableURL(source) {
            return "<img alt=\"\(escape(alt))\">"
        }
        return "<img src=\"\(escape(source))\" alt=\"\(escape(alt))\">"
    }

    /// True when `url`'s scheme runs code instead of fetching a document.
    ///
    /// Reads the scheme the way a URL parser does rather than by prefix match:
    /// ASCII whitespace and C0 controls are ignored wherever they appear
    /// (`java&#9;script:` is `javascript:`), and a `/`, `?` or `#` before any
    /// `:` means there is no scheme at all. Percent-escapes are deliberately
    /// *not* decoded — `%6Aavascript:` is not a valid scheme, so it navigates
    /// nowhere.
    static func isExecutableURL(_ url: String) -> Bool {
        var scheme = ""
        var sawColon = false
        for scalar in url.unicodeScalars {
            if scalar == ":" {
                sawColon = true
                break
            }
            if scalar.value <= 0x20 || scalar.value == 0x7F { continue }
            if scalar == "/" || scalar == "?" || scalar == "#" { return false }
            scheme.unicodeScalars.append(scalar)
        }
        guard sawColon else { return false }
        switch scheme.lowercased() {
        case "javascript", "vbscript": return true
        default: return false
        }
    }

    private static func replace(_ text: String, regex: RegexBox, transform: ([String]) -> String) -> String {
        let ns = text as NSString
        let matches = regex.value.matches(in: text, range: NSRange(location: 0, length: ns.length))
        if matches.isEmpty { return text }
        // Slice out of the native Swift string rather than the bridged
        // NSString: `ns.substring(with:)` allocates an NSString and then a
        // second buffer to bridge it back, while short native slices often fit
        // in the inline small-string form and allocate nothing. The bridged
        // path stays as an exact fallback for the one case native slicing
        // cannot express: an NSRange whose edge falls inside a grapheme
        // cluster, which `Range(_:in:)` refuses.
        func slice(_ range: NSRange) -> String {
            if let converted = Range(range, in: text) { return String(text[converted]) }
            return ns.substring(with: range)
        }
        var result = ""
        result.reserveCapacity(text.count + 16)
        var cursor = 0
        for match in matches {
            result += slice(NSRange(location: cursor, length: match.range.location - cursor))
            var groups = [String]()
            groups.reserveCapacity(match.numberOfRanges)
            for i in 0..<match.numberOfRanges {
                let range = match.range(at: i)
                groups.append(range.location == NSNotFound ? "" : slice(range))
            }
            result += transform(groups)
            cursor = match.range.location + match.range.length
        }
        result += slice(NSRange(location: cursor, length: ns.length - cursor))
        return result
    }

    /// Replaces U+0000 with U+FFFD, per CommonMark 0.31.2 §2.3 *Insecure
    /// characters*: "For security reasons, the Unicode character `U+0000` must
    /// be replaced with the REPLACEMENT CHARACTER (`U+FFFD`)."
    ///
    /// Here that spec rule is also load-bearing for the sanitiser. `park`
    /// mints `"\u{0000}MD<index>\u{0000}"`, `renderBlock` returns any block
    /// with that prefix **verbatim** — bypassing both escapers — and the
    /// restore pass at the end of `compile` splices a parked fragment into any
    /// text matching a whole marker. All three assume no marker can come out of
    /// the source. Without this pass none of that holds: `String(contentsOf:)`
    /// in `LocalDocumentResolver` reads U+0000 straight through (it is valid
    /// UTF-8), so a downloaded `.md` beginning `"\u{0000}MD<script>…"` reached
    /// the page as a live `<script>` in the `file://` origin — the exact
    /// outcome `.compilerOutputOnly` exists to prevent — and a body containing
    /// `"\u{0000}MD0\u{0000}"` could replay a parked fragment.
    ///
    /// Doing it here rather than hardening `renderBlock`'s prefix check makes
    /// the marker unmintable rather than merely unmatched, so the guarantee
    /// survives future changes to how markers are recognised. It applies to
    /// both trust levels: the replay half is not about raw HTML.
    static func sanitizeNULs(_ string: String) -> String {
        string.replacingOccurrences(of: "\u{0000}", with: "\u{FFFD}")
    }

    public static func escape(_ string: String) -> String {
        // Single pass, single output buffer: the old four chained
        // replacingOccurrences calls allocated a full copy per pass.
        var result = ""
        result.reserveCapacity(string.count + string.count / 8)
        var i = string.startIndex
        while i < string.endIndex {
            switch string[i] {
            case "&": result.append("&amp;")
            case "<": result.append("&lt;")
            case ">": result.append("&gt;")
            case "\"": result.append("&quot;")
            default: result.append(string[i])
            }
            i = string.index(after: i)
        }
        return result
    }

    /// Escape text, letting raw tag runs through — CommonMark's inline-HTML
    /// rule. `.rawHTMLAllowed` only; the tag runs it preserves are now always
    /// the *source's* own, since compiler output is parked before this runs.
    private static func escapeLoose(_ string: String) -> String {
        // Single pass like `escape`, but raw tag runs (<...>) pass through
        // untouched. The old per-character `escape(String(string[i]))`
        // allocated a String per character.
        var result = ""
        result.reserveCapacity(string.count + 16)
        var i = string.startIndex
        while i < string.endIndex {
            if string[i] == "<", let close = string[i...].firstIndex(of: ">") {
                result.append(contentsOf: string[i...close])
                i = string.index(after: close)
            } else {
                switch string[i] {
                case "&": result.append("&amp;")
                case "<": result.append("&lt;")
                case ">": result.append("&gt;")
                case "\"": result.append("&quot;")
                default: result.append(string[i])
                }
                i = string.index(after: i)
            }
        }
        return result
    }
}
