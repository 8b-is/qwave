import XCTest
@testable import BrowserCore

final class MarkdownCompilerTests: XCTestCase {
    func testHeadingsListsAndLinks() {
        let html = MarkdownCompiler.compile(
            """
            # Title
            A [link](https://example.com) and **bold**.
            - one
            - two
            """)
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
            """)
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
            """)
        XCTAssertTrue(html.contains("<table>"))
        XCTAssertTrue(html.contains("<th>"))
        XCTAssertTrue(html.contains("<td>1</td>"))
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
        XCTAssertTrue(QwaveSchemeHandler.shouldShowWaveError(status: 404))
        XCTAssertTrue(QwaveSchemeHandler.shouldShowWaveError(status: 503))
        XCTAssertFalse(QwaveSchemeHandler.shouldShowWaveError(status: 401))
        XCTAssertFalse(QwaveSchemeHandler.shouldShowWaveError(status: 200))
    }
}
