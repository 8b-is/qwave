// webgpu-surface probe v2: class-level SPI enumeration (the SPI lives on
// WKPreferences.self on recent WebKit — instance responds-to is false),
// flag experiment per WebGPU-adjacent flag, and the three-way wave
// benchmark (WGSL compute in the web view). Local-only file URLs.
import Foundation
import WebKit

@MainActor
final class ProbeRunner: NSObject, WKScriptMessageHandler {
    var result: String?
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        if let body = message.body as? String { result = body }
    }
}

@MainActor
func rawFeatures() -> (found: Bool, features: [(key: String, name: String, raw: NSObject)]) {
    var found = false
    var seenKeys = Set<String>()
    var merged: [(key: String, name: String, raw: NSObject)] = []
    let instance = WKPreferences()
    for selectorName in ["_features", "_experimentalFeatures", "_internalDebugFeatures"] {
        let selector = NSSelectorFromString(selectorName)
        let source: [NSObject]?
        if WKPreferences.self.responds(to: selector),
            let result = (WKPreferences.self as AnyObject).perform(selector)?.takeUnretainedValue() as? [NSObject]
        {
            source = result
        } else if instance.responds(to: selector),
            let result = instance.perform(selector)?.takeUnretainedValue() as? [NSObject]
        {
            source = result
        } else {
            source = nil
        }
        guard let source else { continue }
        found = true
        for obj in source {
            let key = (obj.value(forKey: "key") as? String) ?? (obj.value(forKey: "keyName") as? String) ?? ""
            let name = (obj.value(forKey: "name") as? String) ?? key
            if key.isEmpty { continue }
            if seenKeys.insert(key).inserted { merged.append((key, name, obj)) }
        }
    }
    return (found, merged)
}

@MainActor
func runPage(page: String, query: String = "", flags: [(String, String, NSObject)] = [], disabled: [(String, String, NSObject)] = [], label: String) -> (String, String) {
    let config = WKWebViewConfiguration()
    config.websiteDataStore = .nonPersistent()
    let runner = ProbeRunner()
    config.userContentController.add(runner, name: "probe")
    let prefs = WKPreferences()
    let setSel = NSSelectorFromString("_setEnabled:forFeature:")
    if prefs.responds(to: setSel) {
        for (_, _, raw) in flags {
            _ = prefs.perform(setSel, with: true, with: raw)
        }
        for (_, _, raw) in disabled {
            _ = prefs.perform(setSel, with: false, with: raw)
        }
    }
    config.preferences = prefs
    let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: config)
    let probeDir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Probe")
    var url = probeDir.appendingPathComponent(page)
    if !query.isEmpty { url = url.appending(queryItems: [URLQueryItem(name: "mode", value: query)]) }
    webView.loadFileURL(url, allowingReadAccessTo: probeDir)
    let deadline = Date().addingTimeInterval(20)
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

let (found, allFeatures) = rawFeatures()
let gpuFlags = allFeatures.filter { $0.key.lowercased().contains("webgpu") || $0.key.lowercased().contains("gpu") }

var surface: [String: Any] = [:]
surface["_found"] = found
surface["_totalFeatures"] = allFeatures.count
surface["_stamps"] = stamps

let (_, baseline) = runPage(page: "probe.html", label: "baseline")
surface["baseline"] = baseline

// Flag experiment: each WebGPU-adjacent flag set TRUE in a fresh ephemeral
// view; WebGPUEnabled also gets a FALSE run to test whether it still gates.
for (key, name, raw) in gpuFlags {
    let (l, json) = runPage(page: "probe.html", flags: [(key, name, raw)], label: "flag:\(key)")
    surface[l] = json
}
if let webgpuFlag = gpuFlags.first(where: { $0.key == "WebGPUEnabled" }) {
    let (l, json) = runPage(
        page: "probe.html",
        disabled: [(webgpuFlag.0, webgpuFlag.1, webgpuFlag.2)],
        label: "flag:WebGPUEnabled(off)")
    surface[l] = json
}

// Wave three-way legs
var wave: [String: Any] = [:]
wave["_stamps"] = stamps
wave["_workload"] = "Lost in the Math fbm, 1512x982, 5 fbm calls/px, baked rotation"
let (wF32, wf32json) = runPage(page: "wave.html", query: "f32", label: "webgpu-f32")
wave[wF32] = wf32json
let (wF16, wf16json) = runPage(page: "wave.html", query: "f16", label: "webgpu-f16")
wave[wF16] = wf16json

let baseDir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let surfaceOut = baseDir.appendingPathComponent("results/webgpu-surface.json")
try (try JSONSerialization.data(withJSONObject: surface, options: [.prettyPrinted, .sortedKeys])).write(to: surfaceOut)
let waveOut = baseDir.appendingPathComponent("results/wave-threeway.json")
try (try JSONSerialization.data(withJSONObject: wave, options: [.prettyPrinted, .sortedKeys])).write(to: waveOut)
print("wrote", surfaceOut.lastPathComponent, "and", waveOut.lastPathComponent)
print("surface found:", found, "features:", allFeatures.count, "gpu flags:", gpuFlags.count)
