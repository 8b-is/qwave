import XCTest
@testable import Persistence

final class BookmarkImporterTests: XCTestCase {
    func testParsesChromiumTreeWithFoldersAndFiltersNonWeb() throws {
        let json = """
            {
              "roots": {
                "bookmark_bar": {
                  "name": "Bookmark bar",
                  "type": "folder",
                  "children": [
                    { "name": "WebKit", "type": "url", "url": "https://webkit.org/" },
                    {
                      "name": "Dev",
                      "type": "folder",
                      "children": [
                        { "name": "Swift", "type": "url", "url": "https://swift.org/" }
                      ]
                    },
                    { "name": "Bad scheme", "type": "url", "url": "javascript:void(0)" },
                    { "name": "Internal", "type": "url", "url": "chrome://settings" }
                  ]
                },
                "other": {
                  "name": "Other bookmarks",
                  "type": "folder",
                  "children": [
                    { "name": "Example", "type": "url", "url": "http://example.com/" }
                  ]
                }
              },
              "version": 1
            }
            """
        let parsed = try BookmarkImporter.parseChromiumJSON(Data(json.utf8))

        XCTAssertEqual(parsed.count, 3)

        XCTAssertEqual(
            parsed[0],
            ImportedBookmark(
                title: "WebKit", url: URL(string: "https://webkit.org/")!, folder: "Bookmark bar"))
        // Nested folder wins over the root name.
        XCTAssertEqual(
            parsed[1],
            ImportedBookmark(
                title: "Swift", url: URL(string: "https://swift.org/")!, folder: "Dev"))
        // "other" root is walked after "bookmark_bar".
        XCTAssertEqual(
            parsed[2],
            ImportedBookmark(
                title: "Example", url: URL(string: "http://example.com/")!, folder: "Other bookmarks"))
    }

    func testMalformedInputThrows() {
        XCTAssertThrowsError(try BookmarkImporter.parseChromiumJSON(Data("not json".utf8))) { error in
            XCTAssertEqual(error as? BookmarkImportError, .malformed)
        }
        XCTAssertThrowsError(try BookmarkImporter.parseChromiumJSON(Data("{\"version\":1}".utf8))) { error in
            XCTAssertEqual(error as? BookmarkImportError, .malformed)
        }
    }

    func testEmptyRootsProducesNoBookmarks() throws {
        let parsed = try BookmarkImporter.parseChromiumJSON(Data("{\"roots\":{}}".utf8))
        XCTAssertTrue(parsed.isEmpty)
    }
}
