import XCTest
import WebKit
@testable import BrowserCore

/// One hostile document, compiled twice.
///
/// Issue #131's split is that the *same* markdown is safe over http(s) and
/// unsafe from `file://`, so the proof has to be a differential rather than a
/// single "is it escaped" check. `Self.source` is compiled under both trust
/// levels and both results are pinned byte-for-byte, which makes the diff
/// between the two goldens the exact statement of what sanitising does.
final class MarkdownSanitisationTests: XCTestCase {
    /// Every shape the issue names — `<script>`, `<img onerror=>`, `<iframe>`,
    /// `javascript:` hrefs, `<svg onload=>`, entity-encoded variants — plus the
    /// constructs that reach the escaper by a different route: headings, table
    /// cells, list items, task items, block quotes, emphasis, code spans,
    /// inline math, and a fence.
    static let source = """
        # Notes <script>alert('heading')</script>

        A raw tag: <script>alert(1)</script> and an <img src=x onerror=alert(2)>
        plus <iframe src="https://evil.example/"></iframe> and
        <svg onload="alert(3)"></svg> and a <b onclick="alert(4)">handler</b>.

        Entity-encoded: &lt;script&gt;alert(5)&lt;/script&gt; and &#60;script&#62;.

        [plain](javascript:alert(6)) and [tabbed](  java\tscript:alert(7))
        and [cased](JaVaScRiPt:alert(8)) and [vb](vbscript:msgbox(9))
        and [safe](https://example.com/a?b=1) and [relative](./other.md).

        ![boom](javascript:alert(10)) and ![ok](./pic.png)

        Inline `<script>alert(11)</script>` in code, *em <b>x</b>*, **strong <i>y</i>**,
        ~~del <u>z</u>~~, and math $a<b$.

        | header <script>alert(12)</script> | b |
        |---|---|
        | cell <img src=x onerror=alert(13)> | & |

        - list <script>alert(14)</script>
        - [ ] task <iframe></iframe>

        > quote <script>alert(15)</script>

        ```html
        <script>alert(16)</script>
        ```
        """

    /// The remote path. CommonMark says inline HTML renders, and a remote
    /// document already runs as its own origin, so raw tags survive — PR #130's
    /// golden for the benign document is the other half of this claim.
    ///
    /// The one intended change against `origin/main` is in the `<code>` span:
    /// it used to read `<code>&amp;lt;script&amp;gt;…</code>` (double-escaped,
    /// issue #131's "related, same file"), because the final escaping pass
    /// walked back over entities the compiler had just written.
    func testRemotePathKeepsRawHTMLByteForByte() {
        let expected = """
            <h1>Notes <script>alert('heading')</script></h1>
            <p>A raw tag: <script>alert(1)</script> and an <img src=x onerror=alert(2)><br>plus <iframe src="https://evil.example/"></iframe> and<br><svg onload="alert(3)"></svg> and a <b onclick="alert(4)">handler</b>.</p>
            <p>Entity-encoded: &amp;lt;script&amp;gt;alert(5)&amp;lt;/script&amp;gt; and &amp;#60;script&amp;#62;.</p>
            <p><a href="javascript:alert(6">plain</a>) and <a href="  java\tscript:alert(7">tabbed</a>)<br>and <a href="JaVaScRiPt:alert(8">cased</a>) and <a href="vbscript:msgbox(9">vb</a>)<br>and <a href="https://example.com/a?b=1">safe</a> and <a href="./other.md">relative</a>.</p>
            <p><img src="javascript:alert(10" alt="boom">) and <img src="./pic.png" alt="ok"></p>
            <p>Inline <code>&lt;script&gt;alert(11)&lt;/script&gt;</code> in code, <em>em &lt;b&gt;x&lt;/b&gt;</em>, <strong>strong &lt;i&gt;y&lt;/i&gt;</strong>,<br><del>del &lt;u&gt;z&lt;/u&gt;</del>, and math <span class="math-inline">a&lt;b</span>.</p>
            <table><thead><tr><th>header <script>alert(12)</script></th><th>b</th></tr></thead><tbody><tr><td>cell <img src=x onerror=alert(13)></td><td>&amp;</td></tr></tbody></table>
            <ul><li>list <script>alert(14)</script></li><li class="task"><input type="checkbox" disabled> task <iframe></iframe></li></ul>
            <blockquote><p>quote <script>alert(15)</script></p></blockquote>
            <pre><code class="language-html">&lt;script&gt;alert(16)&lt;/script&gt;
            </code></pre>
            """
        XCTAssertEqual(MarkdownCompiler.compile(Self.source, trust: .rawHTMLAllowed), expected)
    }

    /// The `file://` path. The second golden the issue asks for: no tag in
    /// here came from the source, and every executable href lost its target.
    func testLocalPathSanitisesByteForByte() {
        let expected = """
            <h1>Notes &lt;script&gt;alert('heading')&lt;/script&gt;</h1>
            <p>A raw tag: &lt;script&gt;alert(1)&lt;/script&gt; and an &lt;img src=x onerror=alert(2)&gt;<br>plus &lt;iframe src=&quot;https://evil.example/&quot;&gt;&lt;/iframe&gt; and<br>&lt;svg onload=&quot;alert(3)&quot;&gt;&lt;/svg&gt; and a &lt;b onclick=&quot;alert(4)&quot;&gt;handler&lt;/b&gt;.</p>
            <p>Entity-encoded: &amp;lt;script&amp;gt;alert(5)&amp;lt;/script&amp;gt; and &amp;#60;script&amp;#62;.</p>
            <p><a>plain</a>) and <a>tabbed</a>)<br>and <a>cased</a>) and <a>vb</a>)<br>and <a href="https://example.com/a?b=1">safe</a> and <a href="./other.md">relative</a>.</p>
            <p><img alt="boom">) and <img src="./pic.png" alt="ok"></p>
            <p>Inline <code>&lt;script&gt;alert(11)&lt;/script&gt;</code> in code, <em>em &lt;b&gt;x&lt;/b&gt;</em>, <strong>strong &lt;i&gt;y&lt;/i&gt;</strong>,<br><del>del &lt;u&gt;z&lt;/u&gt;</del>, and math <span class="math-inline">a&lt;b</span>.</p>
            <table><thead><tr><th>header &lt;script&gt;alert(12)&lt;/script&gt;</th><th>b</th></tr></thead><tbody><tr><td>cell &lt;img src=x onerror=alert(13)&gt;</td><td>&amp;</td></tr></tbody></table>
            <ul><li>list &lt;script&gt;alert(14)&lt;/script&gt;</li><li class="task"><input type="checkbox" disabled> task &lt;iframe&gt;&lt;/iframe&gt;</li></ul>
            <blockquote><p>quote &lt;script&gt;alert(15)&lt;/script&gt;</p></blockquote>
            <pre><code class="language-html">&lt;script&gt;alert(16)&lt;/script&gt;
            </code></pre>
            """
        XCTAssertEqual(MarkdownCompiler.compile(Self.source, trust: .compilerOutputOnly), expected)
    }

    /// Every tag `MarkdownCompiler` can emit. The allowlist the issue asks for
    /// is enforced by construction rather than by matching, but writing it down
    /// is what lets the next test check the claim.
    static let emittedTags: Set<String> = [
        "h1", "h2", "h3", "p", "br", "hr", "ul", "ol", "li", "input",
        "table", "thead", "tbody", "tr", "th", "td", "blockquote",
        "pre", "code", "a", "img", "span", "strong", "em", "del", "div",
    ]

    /// The property behind the golden, stated so a later change to the corpus
    /// cannot quietly weaken it: on the local path *every* tag in the output is
    /// one this compiler emits, and no tag carries an event handler. Walking
    /// the output rather than grepping for `<script` is the difference between
    /// checking an allowlist and checking a blocklist — `&lt;script&gt;` in the
    /// escaped text is inert and a substring search cannot tell the two apart.
    func testLocalPathEmitsOnlyTagsTheCompilerItselfEmits() {
        let html = MarkdownCompiler.compile(Self.source, trust: .compilerOutputOnly)
        var index = html.startIndex
        var seen = 0
        while let open = html[index...].firstIndex(of: "<") {
            let close = html[open...].firstIndex(of: ">") ?? html.index(before: html.endIndex)
            let run = html[html.index(after: open)..<close]
            let body = run.hasPrefix("/") ? run.dropFirst() : run[...]
            let name = String(body.prefix { !$0.isWhitespace && $0 != "/" }).lowercased()
            XCTAssertTrue(Self.emittedTags.contains(name), "source-derived tag survived: <\(run)>")
            XCTAssertFalse(
                run.lowercased().contains(" on"), "event handler survived: <\(run)>")
            for scheme in ["javascript:", "vbscript:"] {
                XCTAssertFalse(run.lowercased().contains(scheme), "executable URL survived: <\(run)>")
            }
            seen += 1
            index = html.index(after: close)
        }
        XCTAssertGreaterThan(seen, 30, "the walk found almost no tags — corpus or output changed shape")

        // Sanitising is not deleting: the readable text is all still there.
        for text in ["alert(1)", "handler", "plain", "tabbed", "cased"] {
            XCTAssertTrue(html.contains(text), "sanitising dropped visible text: \(text)")
        }
    }

    /// `escapeLoose` is what the local path must never reach, so pin the whole
    /// scheme reader rather than only the cases the corpus happens to contain.
    func testExecutableURLDetection() {
        for url in [
            "javascript:alert(1)", "JAVASCRIPT:alert(1)", "JaVaScRiPt:x",
            "  javascript:x", "\tjavascript:x", "java\tscript:x", "java\nscript:x",
            "javascript\u{0}:x", "vbscript:msgbox(1)", "VBScript:x", "javascript:",
        ] {
            XCTAssertTrue(MarkdownCompiler.isExecutableURL(url), "missed: \(url.debugDescription)")
        }
        for url in [
            "https://example.com/", "http://example.com/a:b", "./other.md", "other.md",
            "/abs/path", "#anchor", "?q=javascript:x", "mailto:a@b.example",
            "data:image/png;base64,AAAA", "qwave://start", "", "javascript",
            // Percent-escapes are not decoded by a URL parser either, so this
            // has no scheme and navigates nowhere.
            "%6Aavascript:alert(1)",
            // A path segment that merely contains the word.
            "https://example.com/javascript:alert(1)",
        ] {
            XCTAssertFalse(MarkdownCompiler.isExecutableURL(url), "false positive: \(url.debugDescription)")
        }
    }

    /// The listing path is markdown the *browser* writes
    /// (`LocalDocumentResolver.directoryListingMarkdown`), from names the
    /// browser does not control, and it renders at a `file://` URL.
    ///
    /// The name below carries a `]`, which is what makes it reach the escaper
    /// at all: `directoryListingMarkdown` emits `- [name](href)`, and a name
    /// without a `]` stays inside the link regex, whose captures were always
    /// escaped. With the `]` the link syntax no longer parses and the name
    /// lands in running text — where, before this change, its tags went
    /// through verbatim.
    func testDirectoryListingWithHostileFileNamesIsSanitised() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        // No `/` — a file name cannot contain one, which is also why the
        // closing tag is spelled differently. An opening tag is enough.
        try "x".write(
            to: dir.appendingPathComponent("<script>alert(1)<-script>].txt"), atomically: true, encoding: .utf8)

        guard case .listing(let markdown, _) = LocalDocumentResolver.resolve(dir) else {
            return XCTFail("expected a directory listing")
        }
        let sanitised = MarkdownCompiler.compile(markdown, trust: .compilerOutputOnly)
        XCTAssertFalse(sanitised.contains("<script>"), "listing rendered a live script: \(sanitised)")
        XCTAssertTrue(sanitised.contains("&lt;script&gt;"))

        // And the same input on the remote path still renders it, which is the
        // behaviour the split deliberately keeps — stated here so the two
        // paths cannot silently converge.
        XCTAssertTrue(MarkdownCompiler.compile(markdown, trust: .rawHTMLAllowed).contains("<script>"))
    }
}

/// What issue #131 says nobody had checked: how much a script in a `file://`
/// document can actually do on *this* configuration.
///
/// `WebViewFactory.makeWebView` sets neither `allowFileAccessFromFileURLs` nor
/// `allowUniversalAccessFromFileURLs`, so a plain `WKWebViewConfiguration` is
/// what governs, and that is what this measures. If a future change turns
/// either on, the `.compilerOutputOnly` path stops being "annoying" and starts
/// being "reads your home directory" — so this fails loudly rather than
/// leaving the severity assessment stale.
@MainActor
final class FileOriginCapabilityTests: XCTestCase {
    func testFileURLPrivilegesAreOff() {
        let preferences = WKPreferences()
        XCTAssertEqual(
            (preferences.value(forKey: "allowFileAccessFromFileURLs") as? NSNumber)?.boolValue, false,
            "allowFileAccessFromFileURLs is on: a local .md could read sibling files")
        let configuration = WKWebViewConfiguration()
        XCTAssertEqual(
            (configuration.value(forKey: "allowUniversalAccessFromFileURLs") as? NSNumber)?.boolValue, false,
            "allowUniversalAccessFromFileURLs is on: a local .md could read any origin")
    }

    /// The behavioural half, because the two flags above are SPI and a default
    /// can change: a document loaded the way `presentMarkdown` loads one must
    /// not be able to read a file sitting next to it.
    func testFileOriginDocumentCannotReadASiblingFile() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try "QWAVE-SECRET".write(to: dir.appendingPathComponent("secret.txt"), atomically: true, encoding: .utf8)
        let document = dir.appendingPathComponent("doc.md")
        try "# doc".write(to: document, atomically: true, encoding: .utf8)

        let webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        webView.loadHTMLString(
            """
            <html><body><script>
            window.__read = "pending";
            var x = new XMLHttpRequest();
            x.open("GET", "secret.txt", true);
            x.onload = function () { window.__read = "READ:" + x.responseText; };
            x.onerror = function () { window.__read = "blocked"; };
            try { x.send(); } catch (e) { window.__read = "blocked"; }
            window.__ready = true;
            </script></body></html>
            """,
            baseURL: document
        )

        func evaluate(_ expression: String) async -> String? {
            let value = try? await webView.evaluateJavaScript("String(\(expression))")
            return value as? String
        }

        var ready = false
        for _ in 0..<80 where !ready {
            try? await Task.sleep(nanoseconds: 100_000_000)
            ready = await evaluate("window.__ready === true") == "true"
        }
        try XCTSkipUnless(ready, "WKWebView could not load a document in this test process")

        // The script does run, and it runs in the file:// origin — that is the
        // vulnerability, and it is why the local path sanitises.
        let origin = await evaluate("location.origin")
        XCTAssertEqual(origin, "file://")

        var verdict = "pending"
        for _ in 0..<40 where verdict == "pending" {
            try? await Task.sleep(nanoseconds: 100_000_000)
            verdict = await evaluate("window.__read") ?? "pending"
        }
        XCTAssertEqual(verdict, "blocked", "a file:// document read a sibling file: \(verdict)")
    }
}
