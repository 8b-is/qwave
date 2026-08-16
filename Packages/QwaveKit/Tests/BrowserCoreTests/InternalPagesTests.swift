import XCTest
@testable import BrowserCore

/// These cases predate the `MarkdownTrust` split (issue #131) and describe the
/// CommonMark path, so they all say `.rawHTMLAllowed` explicitly.
/// `MarkdownSanitisationTests` covers the `file://` path.
final class MarkdownCompilerTests: XCTestCase {
    func testHeadingsListsAndLinks() {
        let html = MarkdownCompiler.compile(
            """
            # Title
            A [link](https://example.com) and **bold**.
            - one
            - two
            """, trust: .rawHTMLAllowed)
        XCTAssertTrue(html.contains("<h1>"))
        XCTAssertTrue(html.contains("<a href=\"https://example.com\">link</a>"))
        XCTAssertTrue(html.contains("<strong>bold</strong>"))
        XCTAssertTrue(html.contains("<ul>"))
    }

    func testMermaidAndMathSurvive() {
        let html = MarkdownCompiler.compile(
            """
            $$E = mc^2$$

            Inline $x_i$ here.

            ```mermaid
            graph TD
              A-->B
            ```
            """, trust: .rawHTMLAllowed)
        XCTAssertTrue(html.contains("class=\"math-display\""))
        XCTAssertTrue(html.contains("E = mc^2"))
        XCTAssertTrue(html.contains("class=\"math-inline\""))
        XCTAssertTrue(html.contains("class=\"mermaid\""))
        XCTAssertTrue(html.contains("graph TD"))
        XCTAssertFalse(html.contains("```"))
    }

    func testTable() {
        let html = MarkdownCompiler.compile(
            """
            | a | b |
            |---|---|
            | 1 | 2 |
            """, trust: .rawHTMLAllowed)
        XCTAssertTrue(html.contains("<table>"))
        XCTAssertTrue(html.contains("<th>"))
        XCTAssertTrue(html.contains("<td>1</td>"))
    }

    /// Byte-for-byte lock on the compiler's output for the document the
    /// allocation benchmark compiles. The benchmark drove an allocation
    /// reduction in `compile`; this fixes the HTML so any future optimisation
    /// that changes what is rendered fails here instead of shipping.
    func testBenchmarkDocumentCompilesByteIdentically() {
        let source = """
            # Module Boundaries

            ## Why six packages?

            The split is deliberate: build times, testability, and the
            `QwaveTunnelKit` boundary. Each package is a *reviewable* unit.

            - **BrowserCore** — tabs, hibernation, session restore.
            - **Persistence** — SQLite-backed history and bookmarks.
            - **Shields** — rule compile and the HTTPS-First upgrader.

            | Module | Role | Alloc profile |
            |---|---|---|
            | BrowserCore | tabs, hibernation | measured |
            | Persistence | history at 50k rows | gated |
            | Shields | rule compile | budgeted |

            ```swift
            let tab = Tab(pendingURL: url)
            tab.isPinned = index < 3
            manager.append(tab, select: false)
            ```

            $$
            E = mc^2
            $$

            ```mermaid
            graph TD
              A[WebContent] --> B[GPU process]
              B --> C[Metal]
            ```
            """
        let expected = """
            <h1>Module Boundaries</h1>
            <h2>Why six packages?</h2>
            <p>The split is deliberate: build times, testability, and the<br><code>QwaveTunnelKit</code> boundary. Each package is a <em>reviewable</em> unit.</p>
            <ul><li><strong>BrowserCore</strong> — tabs, hibernation, session restore.</li><li><strong>Persistence</strong> — SQLite-backed history and bookmarks.</li><li><strong>Shields</strong> — rule compile and the HTTPS-First upgrader.</li></ul>
            <table><thead><tr><th>Module</th><th>Role</th><th>Alloc profile</th></tr></thead><tbody><tr><td>BrowserCore</td><td>tabs, hibernation</td><td>measured</td></tr><tr><td>Persistence</td><td>history at 50k rows</td><td>gated</td></tr><tr><td>Shields</td><td>rule compile</td><td>budgeted</td></tr></tbody></table>
            <pre><code class="language-swift">let tab = Tab(pendingURL: url)
            tab.isPinned = index &lt; 3
            manager.append(tab, select: false)
            </code></pre>
            <div class="math-display">E = mc^2</div>
            <pre class="mermaid">graph TD
              A[WebContent] --&gt; B[GPU process]
              B --&gt; C[Metal]</pre>
            """
        XCTAssertEqual(MarkdownCompiler.compile(source, trust: .rawHTMLAllowed), expected)
    }

    /// Escaping proof. Every construct that escapes its content must keep
    /// escaping it: an allocation optimisation that skips or reorders a pass
    /// would be an injection hole, not a speedup.
    func testHostileInputStaysEscaped() {
        XCTAssertEqual(
            MarkdownCompiler.compile("```html\n<script>alert(1)</script>\n```", trust: .rawHTMLAllowed),
            "<pre><code class=\"language-html\">&lt;script&gt;alert(1)&lt;/script&gt;\n</code></pre>")

        XCTAssertEqual(
            MarkdownCompiler.compile("```mermaid\ngraph TD\n  A[\"<script>\"] --> B\n```", trust: .rawHTMLAllowed),
            "<pre class=\"mermaid\">graph TD\n  A[&quot;&lt;script&gt;&quot;] --&gt; B</pre>")

        XCTAssertEqual(
            MarkdownCompiler.compile("$$\n<script>alert(1)</script>\n$$", trust: .rawHTMLAllowed),
            "<div class=\"math-display\">&lt;script&gt;alert(1)&lt;/script&gt;</div>")

        // A quote in an href must not be able to close the attribute and open
        // an event handler.
        let link = MarkdownCompiler.compile(
            "[click](http://evil\"onmouseover=\"alert(1))", trust: .rawHTMLAllowed)
        XCTAssertEqual(link, "<p><a href=\"http://evil&quot;onmouseover=&quot;alert(1\">click</a>)</p>")
        XCTAssertFalse(link.contains("onmouseover=\""))

        // Same for an image's src and alt.
        let image = MarkdownCompiler.compile("![\"x](y\"z)", trust: .rawHTMLAllowed)
        XCTAssertEqual(image, "<p><img src=\"y&quot;z\" alt=\"&quot;x\"></p>")

        // Table cells and inline math escape their content too.
        XCTAssertEqual(
            MarkdownCompiler.compile("| a\" | b |\n|---|---|\n| \"x\" | & |", trust: .rawHTMLAllowed),
            "<table><thead><tr><th>a&quot;</th><th>b</th></tr></thead>"
                + "<tbody><tr><td>&quot;x&quot;</td><td>&amp;</td></tr></tbody></table>")

        // `escape` itself, the primitive every construct above depends on.
        XCTAssertEqual(
            MarkdownCompiler.escape("<script>a & b\"</script>"),
            "&lt;script&gt;a &amp; b&quot;&lt;/script&gt;")
    }
}

final class LocalDocumentResolverTests: XCTestCase {
    func testIndexHtmlWins() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try "# ignored".write(to: dir.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try "<h1>hi</h1>".write(to: dir.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)

        if case .htmlIndex(let file, let root) = LocalDocumentResolver.resolve(dir) {
            XCTAssertEqual(file.lastPathComponent, "index.html")
            XCTAssertEqual(root.path, dir.path)
        } else {
            XCTFail("index.html must win over README.md")
        }
    }

    func testReadmeFallback() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try "# Hello waves".write(to: dir.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)

        if case .markdown(let source, let file) = LocalDocumentResolver.resolve(dir) {
            XCTAssertTrue(source.contains("Hello waves"))
            XCTAssertEqual(file.lastPathComponent, "README.md")
        } else {
            XCTFail("directory without index must open README.md")
        }
    }

    func testListingWhenEmptyOfIndexAndReadme() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try "x".write(to: dir.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)

        if case .listing(let markdown, _) = LocalDocumentResolver.resolve(dir) {
            XCTAssertTrue(markdown.contains("notes.txt"))
        } else {
            XCTFail("expected directory listing")
        }
    }

    func testMarkdownFile() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).md")
        try "hello".write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        if case .markdown(let source, _) = LocalDocumentResolver.resolve(file) {
            XCTAssertEqual(source, "hello")
        } else {
            XCTFail("expected markdown file")
        }
    }
}

final class WavePageTests: XCTestCase {
    func testErrorPageContainsShaderAndEscape() {
        let html = InternalPages.httpErrorHTML(status: 404, host: "example.com")
        XCTAssertTrue(html.contains("fbm"))
        XCTAssertTrue(html.contains("404"))
        XCTAssertTrue(html.contains("Reality Not Found"))
        XCTAssertTrue(html.contains("qwave://start"))
        XCTAssertTrue(html.contains("Initialize Escape Sequence"))
        XCTAssertTrue(html.contains("example.com"))
    }

    func testStartPageContainsAskField() {
        let html = InternalPages.startHTML(
            memories: [StartMemoryChip(title: "Pinned", preview: "wave")],
            providerLabel: "On-device"
        )
        XCTAssertTrue(html.contains("Memory Wave"))
        XCTAssertTrue(html.contains("start-form"))
        XCTAssertTrue(html.contains("Pinned"))
        XCTAssertTrue(html.contains("qwave://runtime/mermaid.min.js"))
        XCTAssertTrue(html.contains("glass"))
        XCTAssertTrue(html.contains("qwave://timeline"))
    }

    func testTimelineSlate() {
        let html = InternalPages.timelineHTML(
            days: [
                TimelineDayView(
                    heading: "Today",
                    items: [
                        TimelineItemView(title: "Example", detail: "9:00 · example.com", href: "https://example.com/")
                    ])
            ],
            summary: "A quiet morning of waves.",
            rememberEverything: true,
            providerLabel: "On-device"
        )
        XCTAssertTrue(html.contains("glass"))
        XCTAssertTrue(html.contains("data-summarize=\"today\""))
        XCTAssertTrue(html.contains("A quiet morning of waves."))
        XCTAssertTrue(html.contains("Example"))
        XCTAssertTrue(html.contains("capturing every page locally"))
    }

    func testMarkdownPageKeepsSourceForRemember() {
        let html = InternalPages.markdownHTML(
            title: "README.md", bodyHTML: "<h1>Hi</h1>", source: "# Hi", allowRemember: true)
        XCTAssertTrue(html.contains("id=\"qwave-source\""))
        XCTAssertTrue(html.contains("data-remember=\"page\""))
        XCTAssertTrue(html.contains("data-remember=\"selection\""))
        XCTAssertTrue(html.contains("# Hi"))
    }

    func testWaveErrorStatuses() {
        XCTAssertTrue(QwaveSchemeHandler.shouldShowWaveError(status: .init(rawValue: 404)))
        XCTAssertTrue(QwaveSchemeHandler.shouldShowWaveError(status: .init(rawValue: 503)))
        XCTAssertFalse(QwaveSchemeHandler.shouldShowWaveError(status: .init(rawValue: 401)))
        XCTAssertFalse(QwaveSchemeHandler.shouldShowWaveError(status: .init(rawValue: 200)))
    }
}
