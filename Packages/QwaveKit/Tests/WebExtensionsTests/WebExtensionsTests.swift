import XCTest
import Foundation
@testable import WebExtensions

/// Tests for the MV3 manifest model, the extension registry, the storage
/// service, and the message router. (The injected JS itself is exercised in
/// the running browser; its surface is asserted here.)
final class MV3ManifestTests: XCTestCase {
    func testDecodesMV3Manifest() throws {
        let json = """
            {
              "name": "Test Extension",
              "version": "1.2.3",
              "manifest_version": 3,
              "permissions": ["storage", "tabs"],
              "action": { "default_popup": "popup.html" },
              "content_scripts": [
                { "matches": ["https://*.example.com/*"], "js": ["content.js"], "run_at": "document_idle" }
              ]
            }
            """
        let manifest = try JSONDecoder().decode(MV3Manifest.self, from: Data(json.utf8))
        XCTAssertEqual(manifest.name, "Test Extension")
        XCTAssertEqual(manifest.manifestVersion, 3)
        XCTAssertEqual(manifest.popupPath, "popup.html")
        XCTAssertEqual(manifest.permissions, ["storage", "tabs"])
        XCTAssertEqual(manifest.contentScripts.first?.matches, ["https://*.example.com/*"])
        XCTAssertEqual(manifest.contentScripts.first?.js, ["content.js"])
    }

    func testLegacyBrowserAction() throws {
        let json = """
            { "name": "Old", "version": "0.1", "browser_action": { "default_popup": "a.html" } }
            """
        let manifest = try JSONDecoder().decode(MV3Manifest.self, from: Data(json.utf8))
        XCTAssertEqual(manifest.popupPath, "a.html")
        XCTAssertEqual(manifest.manifestVersion, 2)
    }
}

@MainActor
final class WebExtensionRegistryTests: XCTestCase {
    private func makeExtensionBundle() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("qwave-ext-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let manifest = """
            { "name": "Popup Ext", "version": "1.0", "manifest_version": 3,
              "action": { "default_popup": "popup.html" } }
            """
        try manifest.write(to: dir.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
        try "<html></html>".write(to: dir.appendingPathComponent("popup.html"), atomically: true, encoding: .utf8)
        return dir
    }

    func testInstallAndReload() throws {
        let suite = "qwave-test-registry-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let registry = WebExtensionRegistry(defaults: defaults)
        let bundle = try makeExtensionBundle()
        let ext = try registry.install(bundleDirectory: bundle)
        XCTAssertEqual(ext.manifest.name, "Popup Ext")
        XCTAssertNotNil(ext.popupURL)

        // A fresh registry instance (same defaults) sees the persisted state.
        let reloaded = WebExtensionRegistry(defaults: defaults)
        XCTAssertEqual(reloaded.extensions.first?.id, ext.id)

        let removed = reloaded.uninstall(extensionID: ext.id)
        XCTAssertNotNil(removed)
        XCTAssertTrue(reloaded.extensions.isEmpty)
        defaults.removePersistentDomain(forName: suite)
    }
}

@MainActor
final class ExtensionStorageServiceTests: XCTestCase {
    private func makeService() -> ExtensionStorageService {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("qwave-ext-storage-\(UUID().uuidString)", isDirectory: true)
        return ExtensionStorageService(directory: dir)
    }

    func testSetGetRemove() throws {
        let service = makeService()
        let id = "ext-test"
        service.set(extensionID: id, items: ["theme": "dark", "count": 3])
        let all = try service.get(extensionID: id, keys: nil)
        XCTAssertEqual(all["theme"] as? String, "dark")
        XCTAssertEqual(all["count"] as? Int, 3)

        let single = try service.get(extensionID: id, keys: "theme")
        XCTAssertEqual(single["theme"] as? String, "dark")
        XCTAssertNil(single["count"])

        let subset = try service.get(extensionID: id, keys: ["theme", "missing"])
        XCTAssertEqual(subset.count, 1)

        service.set(extensionID: id, items: ["theme": "light"])
        XCTAssertEqual(try service.get(extensionID: id, keys: "theme")["theme"] as? String, "light")

        try service.remove(extensionID: id, keys: "theme")
        XCTAssertTrue(try service.get(extensionID: id, keys: "theme").isEmpty)
        XCTAssertEqual(try service.get(extensionID: id, keys: "count")["count"] as? Int, 3)
    }

    func testIsolationBetweenExtensions() throws {
        let service = makeService()
        service.set(extensionID: "ext-a", items: ["k": "a"])
        service.set(extensionID: "ext-b", items: ["k": "b"])
        XCTAssertEqual(try service.get(extensionID: "ext-a", keys: "k")["k"] as? String, "a")
        XCTAssertEqual(try service.get(extensionID: "ext-b", keys: "k")["k"] as? String, "b")
    }
}

@MainActor
private final class RecordingResponder: ExtensionMessageResponding {
    var responses: [(id: Int, success: Bool, value: Any?)] = []
    func respond(id: Int, success: Bool, value: Any?) {
        responses.append((id, success, value))
    }
}

@MainActor
final class ExtensionMessageRouterTests: XCTestCase {
    private func makeRouter() -> (router: ExtensionMessageRouter, responder: RecordingResponder) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("qwave-ext-router-\(UUID().uuidString)", isDirectory: true)
        let defaults = UserDefaults(suiteName: "qwave-test-router-\(UUID().uuidString)")!
        let router = ExtensionMessageRouter(
            registry: WebExtensionRegistry(defaults: defaults),
            storage: ExtensionStorageService(directory: dir)
        )
        let responder = RecordingResponder()
        router.responder = responder
        return (router, responder)
    }

    func testStorageRouting() {
        let (router, responder) = makeRouter()
        router.handle(
            ExtensionBridgeCall(id: 1, method: "storage.local.set", args: [["pref": "on"]]), extensionID: "e1")
        router.handle(ExtensionBridgeCall(id: 2, method: "storage.local.get", args: [NSNull()]), extensionID: "e1")
        XCTAssertEqual(responder.responses.count, 2)
        XCTAssertEqual(responder.responses[1].id, 2)
        XCTAssertEqual((responder.responses[1].value as? [String: Any])?["pref"] as? String, "on")

        router.handle(ExtensionBridgeCall(id: 3, method: "storage.local.remove", args: [["pref"]]), extensionID: "e1")
        router.handle(ExtensionBridgeCall(id: 4, method: "storage.local.get", args: [NSNull()]), extensionID: "e1")
        let afterRemove = responder.responses.last?.value as? [String: Any]
        XCTAssertEqual(afterRemove?.isEmpty, true)
    }

    func testTabQueryRouting() {
        let (router, responder) = makeRouter()
        router.tabQueryHandler = { query in
            XCTAssertEqual(query["active"] as? Bool, true)
            return [["id": 7, "url": "https://example.com"]]
        }
        router.handle(ExtensionBridgeCall(id: 4, method: "tabs.query", args: [["active": true]]), extensionID: "e1")
        let tabs = responder.responses.first?.value as? [[String: Any]]
        XCTAssertEqual(tabs?.first?["id"] as? Int, 7)
    }

    func testTabCreateRouting() {
        let (router, _) = makeRouter()
        var created: [String: Any]?
        router.tabCreateHandler = { props in created = props }
        router.handle(
            ExtensionBridgeCall(id: 5, method: "tabs.create", args: [["url": "https://qwave.app"]]), extensionID: "e1")
        XCTAssertEqual(created?["url"] as? String, "https://qwave.app")
    }

    func testRuntimeSendMessageWithAsyncReply() {
        let (router, responder) = makeRouter()
        router.runtimeMessageHandler = { payload, reply in
            XCTAssertEqual(payload as? String, "ping")
            reply("pong")
        }
        router.handle(ExtensionBridgeCall(id: 6, method: "runtime.sendMessage", args: ["ping"]), extensionID: "e1")
        XCTAssertEqual(responder.responses.first?.value as? String, "pong")
    }

    func testRuntimeSendMessageWithDelayedReply() async {
        let (router, responder) = makeRouter()
        router.runtimeMessageHandler = { payload, reply in
            XCTAssertEqual(payload as? String, "ping")
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 10_000_000)
                reply("pong")
            }
        }

        router.handle(ExtensionBridgeCall(id: 10, method: "runtime.sendMessage", args: ["ping"]), extensionID: "e1")
        XCTAssertTrue(responder.responses.isEmpty)

        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(responder.responses.count, 1)
        XCTAssertEqual(responder.responses.first?.id, 10)
        XCTAssertEqual(responder.responses.first?.value as? String, "pong")
    }

    func testNestedBridgeArgumentsRouteWithoutLeavingMainActor() throws {
        let (router, responder) = makeRouter()
        router.handle(
            ExtensionBridgeCall(
                id: 7,
                method: "storage.local.set",
                args: [["settings": ["theme": "dark", "zoom": 1.25]]]
            ),
            extensionID: "e1"
        )
        router.handle(
            ExtensionBridgeCall(id: 8, method: "storage.local.get", args: [["settings"]]),
            extensionID: "e1"
        )

        let settings = try XCTUnwrap(
            (responder.responses.last?.value as? [String: Any])?["settings"] as? [String: Any]
        )
        XCTAssertEqual(settings["theme"] as? String, "dark")
        XCTAssertEqual(settings["zoom"] as? Double, 1.25)
    }

    func testUnknownMethodFails() {
        let (router, responder) = makeRouter()
        router.handle(ExtensionBridgeCall(id: 9, method: "nope.nope", args: []), extensionID: "e1")
        XCTAssertEqual(responder.responses.first?.success, false)
    }
}

final class BrowserBridgeScriptTests: XCTestCase {
    func testBridgeSurface() {
        let source = BrowserBridgeScript.source
        XCTAssertTrue(source.contains("runtime.sendMessage"))
        XCTAssertTrue(source.contains("tabs.query"))
        XCTAssertTrue(source.contains("tabs.create"))
        XCTAssertTrue(source.contains("storage.local.get"))
        XCTAssertTrue(source.contains("storage.local.set"))
        XCTAssertTrue(source.contains("storage.local.remove"))
        XCTAssertTrue(source.contains("__qwaveNative"))
        XCTAssertTrue(source.contains("respond(id, ok, value)"))
        XCTAssertTrue(source.contains("window.browser"))
        XCTAssertTrue(source.contains("window.chrome"))
        XCTAssertEqual(BrowserBridgeScript.messageHandlerName, "qwaveExtension")
    }
}
