import XCTest

@testable import BrowserCore

final class DownloadManagerTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("qwave-downloads-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testUniqueWhenNoCollision() {
        let url = DownloadManager.collisionFreeURL(for: "report.pdf", in: directory)
        XCTAssertEqual(url.lastPathComponent, "report.pdf")
    }

    func testNumbersCollisionsFinderStyle() throws {
        FileManager.default.createFile(atPath: directory.appendingPathComponent("report.pdf").path, contents: Data())
        let second = DownloadManager.collisionFreeURL(for: "report.pdf", in: directory)
        XCTAssertEqual(second.lastPathComponent, "report (2).pdf")

        FileManager.default.createFile(atPath: second.path, contents: Data())
        let third = DownloadManager.collisionFreeURL(for: "report.pdf", in: directory)
        XCTAssertEqual(third.lastPathComponent, "report (3).pdf")
    }

    func testExtensionlessCollisions() {
        FileManager.default.createFile(atPath: directory.appendingPathComponent("archive").path, contents: Data())
        let url = DownloadManager.collisionFreeURL(for: "archive", in: directory)
        XCTAssertEqual(url.lastPathComponent, "archive (2)")
    }
}
