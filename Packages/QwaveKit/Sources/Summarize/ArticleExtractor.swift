import Foundation
import WebKit

/// Runs the readability-probe extractor on explicit command only.
///
/// Parity rule (docs/SUMMARIZE.md): the script in `Resources/extractor.js`
/// is **byte-identical** to
/// `research/02-on-device-ai/readability-probe/Extractor/extractor.js`, so
/// the probe's F1 table (1.00 / 1.00 / 1.00 / 1.00 / 0.96) stays load-bearing
/// for the product. The probe script transports its result through a
/// `probe`-named message handler; the coordinator registers one per
/// invocation and removes it afterwards, so the script itself never forks.
///
/// Both probe fixes are kept verbatim: boilerplate filtering happens at
/// extraction time (the paywall-leak fix), and the readyState-race fallback
/// re-evaluates the script after the page reports `complete`. The <20-char
/// filter's known cost (short table cells are dropped) is a design note, not
/// a rewrite.
public enum ArticleExtractor {
    /// Bundled script; identical to the probe's committed file.
    public static var script: String {
        guard
            let url = Bundle.module.url(forResource: "extractor", withExtension: "js"),
            let source = try? String(contentsOf: url, encoding: .utf8)
        else {
            return ""
        }
        return source
    }

    private final class Receiver: NSObject, WKScriptMessageHandler {
        var message: String?
        func userContentController(
            _ userContentController: WKUserContentController, didReceive message: WKScriptMessage
        ) {
            if let body = message.body as? String { self.message = body }
        }
    }

    /// Extracts the article text (a JSON payload with `text`). Returns nil on
    /// timeout or when the script is missing. Main-actor bound: WKWebView
    /// message handlers and evaluateJavaScript are main-thread APIs.
    @MainActor
    public static func extract(from webView: WKWebView) async -> String? {
        let source = script
        guard !source.isEmpty else { return nil }
        let receiver = Receiver()
        let controller = webView.configuration.userContentController
        controller.add(receiver, name: "probe")
        defer { controller.removeScriptMessageHandler(forName: "probe") }

        webView.evaluateJavaScript(source, completionHandler: nil)
        // Wait for the posted message (the script is synchronous; 15 s covers
        // a slow first layout).
        let deadline = Date().addingTimeInterval(15)
        while receiver.message == nil && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        // readyState race: if the page was still loading, the script may have
        // run against a partial DOM. Wait for complete, then re-evaluate.
        if receiver.message == nil {
            var complete = false
            let loadDeadline = Date().addingTimeInterval(10)
            while !complete && Date() < loadDeadline {
                let result: Any? = try? await webView.evaluateJavaScript("document.readyState")
                complete = result as? String == "complete"
                if !complete { try? await Task.sleep(for: .milliseconds(100)) }
            }
            guard complete else { return nil }
            let result: Any? = try? await webView.evaluateJavaScript(source)
            if let json = result as? String { receiver.message = json }
        }
        return receiver.message
    }

    /// Decodes the extractor's JSON payload into plain text for the session.
    public static func text(from json: String) -> String? {
        guard
            let data = json.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        let text = object["text"] as? String ?? ""
        return text.isEmpty ? nil : text
    }
}
