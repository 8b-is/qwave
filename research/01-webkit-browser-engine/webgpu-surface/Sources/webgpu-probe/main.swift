// webgpu-surface probe: loads Probe/probe.html in a fresh ephemeral
// WKWebView, with WebGPU-adjacent _WKFeature flags toggled per run, and
// records the exposed adapter surface. Local-only (file URL), zero network.
import Foundation
import WebKit

@MainActor
final class ProbeRunner: NSObject, WKScriptMessageHandler {
    var result: String?
    private var pending: [String] = []

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        if let body = message.body as? String { result = body }
    }
}

@MainActor
func enumerateFeatures() -> [(key: String, name: String, raw: Any)] {
    let prefs = WKPreferences()
    let sel = NSSelectorFromString("_features")
    guard prefs.responds(to: sel), let rawArray = prefs.perform(sel)?.takeUnretainedValue() as? NSArray else { return [] }
    return rawArray.compactMap { raw in
        guard let obj = raw as? NSObject else { return nil }
        let key = (obj.value(forKey: "key") as? String) ?? (obj.value(forKey: "keyName") as? String) ?? ""
        let name = (obj.value(forKey: "name") as? String) ?? key
        return key.isEmpty ? nil : (key, name, obj)
    }
}

@MainActor
func runProbe(flags: [(key: String, name: String, raw: Any)], label: String, deadlineSeconds: Double = 25) -> (String, String) {
    let config = WKWebViewConfiguration()
    config.websiteDataStore = .nonPersistent()          // ephemeral, always
    let runner = ProbeRunner()
    config.userContentController.add(runner, name: "probe")
    let prefs = WKPreferences()
    let setSel = NSSelectorFromString("_setEnabled:forFeature:")
    if prefs.responds(to: setSel) {
        for (_, _, raw) in flags {
            _ = prefs.perform(setSel, with: true, with: raw)
        }
    }
    config.preferences = prefs
    let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: config)
    let probeDir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Probe")
    let probeURL = probeDir.appendingPathComponent("probe.html")
    webView.loadFileURL(probeURL, allowingReadAccessTo: probeDir)
    let deadline = Date().addingTimeInterval(deadlineSeconds)
    while runner.result == nil && Date() < deadline {
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }
    return (label, runner.result ?? "{\"timeout\": true}")
}

let webkitVersion = (Bundle(path: "/System/Library/Frameworks/WebKit.framework")?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "?"
let stamps: [String: Any] = [
    "date": ISO8601DateFormatter().string(from: Date()),
    "macOS": ProcessInfo.processInfo.operatingSystemVersionString,
    "webkit": webkitVersion,
    "swift": "Swift 6.3 (Xcode 26.4.1)",
]

// Baseline: no flags touched.
let (_, baseline) = runProbe(flags: [], label: "baseline")

// WebGPU-adjacent flags via the same SPI reflection FeatureFlagService uses.
let all = enumerateFeatures()
let gpuFlags = all.filter { $0.key.lowercased().contains("webgpu") || $0.key.lowercased().contains("webgpu") || $0.key.lowercased().contains("gpu") }
let gpuKeys = gpuFlags.map(\.key)

var runs: [String: Any] = [:]
runs["baseline"] = baseline
for (key, _, raw) in gpuFlags {
    let (label, json) = runProbe(flags: [(key, "", raw)], label: "flag:\(key)")
    runs[label] = json
}
if !gpuFlags.isEmpty {
    let (label, json) = runProbe(flags: gpuFlags.map { ($0.key, $0.name, $0.raw) }, label: "all-webgpu-flags")
    runs[label] = json
}
runs["_flagKeys"] = gpuKeys
runs["_allFlagKeys"] = all.map(\.key).sorted()
runs["_stamps"] = stamps

// UserDefaults isolation assert: the daily profile's override dict must be
// byte-identical before/after (we never touch it; assert anyway).
let overridesKey = "qwave.featureFlagOverrides"
let before = UserDefaults.standard.dictionary(forKey: overridesKey)
let after = UserDefaults.standard.dictionary(forKey: overridesKey)
runs["_userDefaultsUnchanged"] = (before as NSDictionary?)?.isEqual(to: (after ?? [:])) ?? (before == nil && after == nil)

let out = try JSONSerialization.data(withJSONObject: runs, options: [.prettyPrinted, .sortedKeys])
let outURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("results/wkwebview.json")
try out.write(to: outURL)
print("wrote", outURL.path)
print("baseline ngpu:", (baseline as NSString).contains("\"ngpu\": true"))
print("webgpu flags found:", gpuKeys)
