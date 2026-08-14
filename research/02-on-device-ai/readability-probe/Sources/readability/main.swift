// readability-probe: loads each committed fixture in a WKWebView, injects
// Extractor/extractor.js, collects the extraction, writes results.json.
import Foundation
import WebKit

@MainActor
final class Runner: NSObject, WKScriptMessageHandler {
    var result: String?
    func userContentController(_ u: WKUserContentController, didReceive m: WKScriptMessage) {
        if let b = m.body as? String { result = b }
    }
}

@MainActor
func runFixture(_ name: String) -> (String, String) {
    let config = WKWebViewConfiguration()
    config.websiteDataStore = .nonPersistent()
    let runner = Runner()
    config.userContentController.add(runner, name: "probe")
    let wv = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: config)
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    let fixtureDir = root.appendingPathComponent("Fixtures")
    let extractorURL = root.appendingPathComponent("Extractor/extractor.js")
    let extractor = try! String(contentsOf: extractorURL)
    let fixtureURL = fixtureDir.appendingPathComponent(name + ".html")
    wv.loadFileURL(fixtureURL, allowingReadAccessTo: fixtureDir)
    let deadline = Date().addingTimeInterval(15)
    while runner.result == nil && Date() < deadline {
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }
    // If the page didn't post (extractor raced the load), evaluate after load.
    if runner.result == nil {
        var loaded = false
        let d2 = Date().addingTimeInterval(10)
        while !loaded && Date() < d2 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            wv.evaluateJavaScript("document.readyState") { r, _ in loaded = (r as? String) == "complete" }
        }
        wv.evaluateJavaScript(extractor) { r, _ in
            if let r { runner.result = "\(r)" }
        }
        let d3 = Date().addingTimeInterval(5)
        while runner.result == nil && Date() < d3 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
    }
    return (name, runner.result ?? "{\"error\": \"no result\"}")
}

let fixtures = ["news-article", "docs-page", "dense-technical", "paywalled-teaser", "spa-rendered"]
var results: [String: Any] = [:]
results["_stamps"] = ["date": ISO8601DateFormatter().string(from: Date()), "macOS": ProcessInfo.processInfo.operatingSystemVersionString]
for f in fixtures {
    let (n, json) = runFixture(f)
    results[n] = json
}
let out = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("results.json")
try (try JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys])).write(to: out)
print("wrote results.json")
