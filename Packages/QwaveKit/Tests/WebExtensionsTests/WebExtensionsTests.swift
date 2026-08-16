import XCTest
import Foundation
import WebKit
@testable import WebExtensions

/// Tests for the MV3 manifest model, the extension registry, the storage
/// service, content script engine, and the message router.
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
        XCTAssertEqual(manifest.contentScripts.first?.runAt, "document_idle")
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

final class URLMatchPatternTests: XCTestCase {
    func testAllURLsPattern() throws {
        let pattern = try XCTUnwrap(URLMatchPattern("<all_urls>"))
        XCTAssertTrue(pattern.isAllURLs)
        XCTAssertTrue(pattern.matches("https://google.com/search"))
        XCTAssertTrue(pattern.matches("http://localhost:8080/test"))
        XCTAssertTrue(pattern.matches("file:///Users/peter/doc.html"))
        XCTAssertTrue(pattern.matches("ws://example.com/socket"))
        XCTAssertFalse(pattern.matches("chrome://settings"))
        XCTAssertFalse(pattern.matches("about:blank"))
    }

    func testWildcardSchemeAndHost() throws {
        let pattern = try XCTUnwrap(URLMatchPattern("*://*.example.com/*"))
        XCTAssertFalse(pattern.isAllURLs)
        XCTAssertEqual(pattern.schemePattern, "*")
        XCTAssertEqual(pattern.hostPattern, "*.example.com")
        XCTAssertTrue(pattern.matches("https://example.com/"))
        XCTAssertTrue(pattern.matches("https://sub.example.com/path/to/page"))
        XCTAssertTrue(pattern.matches("http://a.b.example.com/test?q=1"))
        XCTAssertFalse(pattern.matches("ftp://example.com/"))
        XCTAssertFalse(pattern.matches("https://notexample.com/"))
    }

    func testExactHostAndPathPrefix() throws {
        let pattern = try XCTUnwrap(URLMatchPattern("https://example.org/api/*"))
        XCTAssertTrue(pattern.matches("https://example.org/api/v1/users"))
        XCTAssertFalse(pattern.matches("https://example.org/other"))
        XCTAssertFalse(pattern.matches("http://example.org/api/v1/users"))
    }

    func testInvalidPatterns() {
        XCTAssertNil(URLMatchPattern(""))
        XCTAssertNil(URLMatchPattern("invalid-pattern"))
        XCTAssertNil(URLMatchPattern("http://"))
        XCTAssertNil(URLMatchPattern("custom://foo/*"))
    }
}

final class ContentScriptEngineTests: XCTestCase {
    func testContentScriptResolutionAndMapping() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("qwave-test-cs-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let manifest = MV3Manifest(
            name: "CS Extension",
            version: "1.0.0",
            manifestVersion: 3,
            contentScripts: [
                MV3Manifest.ContentScript(
                    matches: ["https://*.github.com/*"],
                    js: ["start.js"],
                    runAt: "document_start"
                ),
                MV3Manifest.ContentScript(
                    matches: ["https://*.github.com/*", "https://*.gitlab.com/*"],
                    js: ["end.js"],
                    runAt: "document_end"
                ),
            ]
        )

        let ext = WebExtension(id: "ext-cs-test", manifest: manifest, bundleURL: dir)
        let engine = ContentScriptEngine()

        let fileLoader: (URL) throws -> String = { url in
            if url.lastPathComponent == "start.js" {
                return "console.log('start');"
            } else if url.lastPathComponent == "end.js" {
                return "console.log('end');"
            }
            throw NSError(domain: "test", code: 404)
        }

        // Matching GitHub URL
        let ghURL = URL(string: "https://sub.github.com/peterlodri-sec/qwave")!
        let ghScripts = engine.resolveScripts(for: ghURL, extensions: [ext], fileLoader: fileLoader)
        XCTAssertEqual(ghScripts.count, 2)
        XCTAssertEqual(ghScripts[0].relativePath, "start.js")
        XCTAssertEqual(ghScripts[0].injectionTime, .atDocumentStart)
        XCTAssertTrue(ghScripts[0].source.contains("console.log('start');"))
        XCTAssertEqual(ghScripts[1].relativePath, "end.js")
        XCTAssertEqual(ghScripts[1].injectionTime, .atDocumentEnd)

        // Matching GitLab URL (only 1 script matches)
        let glURL = URL(string: "https://gitlab.com/repo/project")!
        let glScripts = engine.resolveScripts(for: glURL, extensions: [ext], fileLoader: fileLoader)
        XCTAssertEqual(glScripts.count, 1)
        XCTAssertEqual(glScripts[0].relativePath, "end.js")

        // Non-matching URL
        let otherURL = URL(string: "https://apple.com/")!
        let otherScripts = engine.resolveScripts(for: otherURL, extensions: [ext], fileLoader: fileLoader)
        XCTAssertTrue(otherScripts.isEmpty)
    }

    @MainActor
    func testContentScriptInstallationIntoUserContentController() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("qwave-test-cs-install-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "window.__csInjected = true;".write(
            to: dir.appendingPathComponent("inject.js"),
            atomically: true,
            encoding: .utf8
        )

        let manifest = MV3Manifest(
            name: "CS Install",
            version: "1.0",
            manifestVersion: 3,
            contentScripts: [
                MV3Manifest.ContentScript(
                    matches: ["https://*.example.com/*"],
                    js: ["inject.js"],
                    runAt: "document_idle"
                )
            ]
        )

        let ext = WebExtension(id: "ext-install-test", manifest: manifest, bundleURL: dir)
        let engine = ContentScriptEngine()
        let controller = WKUserContentController()

        let targetURL = URL(string: "https://sub.example.com/page")!
        engine.installContentScripts(into: controller, for: targetURL, extensions: [ext])

        XCTAssertEqual(controller.userScripts.count, 1)
        XCTAssertEqual(controller.userScripts.first?.injectionTime, .atDocumentEnd)
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
    /// Installs a real extension bundle declaring `permissions` into the
    /// router's registry and returns its resolved `id`, so tests exercise the
    /// same permission gate production traffic goes through rather than an
    /// arbitrary unregistered string.
    @discardableResult
    private func installExtension(
        into registry: WebExtensionRegistry, permissions: [String] = ["storage", "tabs"]
    ) throws -> String {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("qwave-ext-router-bundle-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let permissionsJSON = permissions.map { "\"\($0)\"" }.joined(separator: ", ")
        let manifest = """
            { "name": "Router Test Ext", "version": "1.0", "manifest_version": 3,
              "permissions": [\(permissionsJSON)] }
            """
        try manifest.write(to: dir.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
        let ext = try registry.install(bundleDirectory: dir)
        return ext.id
    }

    private func makeRouter(permissions: [String] = ["storage", "tabs"]) throws -> (
        router: ExtensionMessageRouter, responder: RecordingResponder, extensionID: String
    ) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("qwave-ext-router-\(UUID().uuidString)", isDirectory: true)
        let defaults = UserDefaults(suiteName: "qwave-test-router-\(UUID().uuidString)")!
        let registry = WebExtensionRegistry(defaults: defaults)
        let extensionID = try installExtension(into: registry, permissions: permissions)
        let router = ExtensionMessageRouter(
            registry: registry,
            storage: ExtensionStorageService(directory: dir)
        )
        let responder = RecordingResponder()
        router.responder = responder
        return (router, responder, extensionID)
    }

    func testStorageRouting() throws {
        let (router, responder, extensionID) = try makeRouter()
        router.handle(
            ExtensionBridgeCall(id: 1, method: "storage.local.set", args: [["pref": "on"]]), extensionID: extensionID)
        router.handle(
            ExtensionBridgeCall(id: 2, method: "storage.local.get", args: [NSNull()]), extensionID: extensionID)
        XCTAssertEqual(responder.responses.count, 2)
        XCTAssertEqual(responder.responses[1].id, 2)
        XCTAssertEqual((responder.responses[1].value as? [String: Any])?["pref"] as? String, "on")

        router.handle(
            ExtensionBridgeCall(id: 3, method: "storage.local.remove", args: [["pref"]]), extensionID: extensionID)
        router.handle(
            ExtensionBridgeCall(id: 4, method: "storage.local.get", args: [NSNull()]), extensionID: extensionID)
        let afterRemove = responder.responses.last?.value as? [String: Any]
        XCTAssertEqual(afterRemove?.isEmpty, true)
    }

    func testTabQueryRouting() throws {
        let (router, responder, extensionID) = try makeRouter()
        router.tabQueryHandler = { query in
            XCTAssertEqual(query["active"] as? Bool, true)
            return [["id": 7, "url": "https://example.com"]]
        }
        router.handle(
            ExtensionBridgeCall(id: 4, method: "tabs.query", args: [["active": true]]), extensionID: extensionID)
        let tabs = responder.responses.first?.value as? [[String: Any]]
        XCTAssertEqual(tabs?.first?["id"] as? Int, 7)
    }

    func testTabCreateRouting() throws {
        let (router, _, extensionID) = try makeRouter()
        var created: [String: Any]?
        router.tabCreateHandler = { props in created = props }
        router.handle(
            ExtensionBridgeCall(id: 5, method: "tabs.create", args: [["url": "https://qwave.app"]]),
            extensionID: extensionID)
        XCTAssertEqual(created?["url"] as? String, "https://qwave.app")
    }

    func testRuntimeSendMessageWithAsyncReply() throws {
        let (router, responder, extensionID) = try makeRouter()
        router.runtimeMessageHandler = { payload, reply in
            XCTAssertEqual(payload as? String, "ping")
            reply("pong")
        }
        router.handle(
            ExtensionBridgeCall(id: 6, method: "runtime.sendMessage", args: ["ping"]), extensionID: extensionID)
        XCTAssertEqual(responder.responses.first?.value as? String, "pong")
    }

    func testRuntimeSendMessageWithDelayedReply() async throws {
        let (router, responder, extensionID) = try makeRouter()
        router.runtimeMessageHandler = { payload, reply in
            XCTAssertEqual(payload as? String, "ping")
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 10_000_000)
                reply("pong")
            }
        }

        router.handle(
            ExtensionBridgeCall(id: 10, method: "runtime.sendMessage", args: ["ping"]), extensionID: extensionID)
        XCTAssertTrue(responder.responses.isEmpty)

        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(responder.responses.count, 1)
        XCTAssertEqual(responder.responses.first?.id, 10)
        XCTAssertEqual(responder.responses.first?.value as? String, "pong")
    }

    func testOnMessageReplyRouting() throws {
        let (router, _, extensionID) = try makeRouter()
        var replyReceivedId: Int?
        var replyReceivedPayload: Any?
        router.onMessageReplyHandler = { id, payload in
            replyReceivedId = id
            replyReceivedPayload = payload
        }

        router.handle(
            ExtensionBridgeCall(id: 42, method: "runtime.onMessageReply", args: [["status": "acknowledged"]]),
            extensionID: extensionID
        )

        XCTAssertEqual(replyReceivedId, 42)
        XCTAssertEqual((replyReceivedPayload as? [String: Any])?["status"] as? String, "acknowledged")
    }

    func testNestedBridgeArgumentsRouteWithoutLeavingMainActor() throws {
        let (router, responder, extensionID) = try makeRouter()
        router.handle(
            ExtensionBridgeCall(
                id: 7,
                method: "storage.local.set",
                args: [["settings": ["theme": "dark", "zoom": 1.25]]]
            ),
            extensionID: extensionID
        )
        router.handle(
            ExtensionBridgeCall(id: 8, method: "storage.local.get", args: [["settings"]]),
            extensionID: extensionID
        )

        let settings = try XCTUnwrap(
            (responder.responses.last?.value as? [String: Any])?["settings"] as? [String: Any]
        )
        XCTAssertEqual(settings["theme"] as? String, "dark")
        XCTAssertEqual(settings["zoom"] as? Double, 1.25)
    }

    func testUnknownMethodFails() throws {
        let (router, responder, extensionID) = try makeRouter()
        router.handle(ExtensionBridgeCall(id: 9, method: "nope.nope", args: []), extensionID: extensionID)
        XCTAssertEqual(responder.responses.first?.success, false)
    }

    /// A reply must land on the surface the call came from, never on whichever
    /// responder happened to register last.
    func testReplyGoesToTheCallingSurfaceNotTheSharedSlot() throws {
        let (router, sharedSlot, extensionID) = try makeRouter()
        let callingSurface = RecordingResponder()
        router.handle(
            ExtensionBridgeCall(id: 11, method: "storage.local.set", args: [["pref": "on"]]),
            extensionID: extensionID,
            replyTo: callingSurface
        )
        XCTAssertEqual(callingSurface.responses.count, 1)
        XCTAssertEqual(callingSurface.responses.first?.id, 11)
        XCTAssertTrue(sharedSlot.responses.isEmpty)
    }

    /// The async `runtime.sendMessage` reply must also stay on the calling surface.
    func testAsyncReplyGoesToTheCallingSurface() async throws {
        let (router, sharedSlot, extensionID) = try makeRouter()
        let callingSurface = RecordingResponder()
        router.runtimeMessageHandler = { _, reply in
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 10_000_000)
                reply("pong")
            }
        }
        router.handle(
            ExtensionBridgeCall(id: 12, method: "runtime.sendMessage", args: ["ping"]),
            extensionID: extensionID,
            replyTo: callingSurface
        )
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(callingSurface.responses.first?.value as? String, "pong")
        XCTAssertTrue(sharedSlot.responses.isEmpty)
    }

    // MARK: - Permission gate (#75)

    /// An extension that never declared `storage` in its manifest must not be
    /// able to reach `storage.local.*` — declaring permissions, or omitting
    /// them, must not produce identical runtime behaviour.
    func testStorageDeniedWithoutStoragePermission() throws {
        let (router, responder, extensionID) = try makeRouter(permissions: ["tabs"])
        router.handle(
            ExtensionBridgeCall(id: 1, method: "storage.local.set", args: [["pref": "on"]]), extensionID: extensionID)
        XCTAssertEqual(responder.responses.first?.success, false)
        XCTAssertEqual(responder.responses.first?.value as? String, "Missing permission: storage")

        router.handle(
            ExtensionBridgeCall(id: 2, method: "storage.local.get", args: [NSNull()]), extensionID: extensionID)
        XCTAssertEqual(responder.responses.last?.success, false)

        router.handle(
            ExtensionBridgeCall(id: 3, method: "storage.local.remove", args: [["pref"]]), extensionID: extensionID)
        XCTAssertEqual(responder.responses.last?.success, false)
    }

    /// The mirror case: declaring `storage` grants access.
    func testStorageAllowedWithStoragePermission() throws {
        let (router, responder, extensionID) = try makeRouter(permissions: ["storage"])
        router.handle(
            ExtensionBridgeCall(id: 1, method: "storage.local.set", args: [["pref": "on"]]), extensionID: extensionID)
        XCTAssertEqual(responder.responses.first?.success, true)
    }

    /// An extension that never declared `tabs` must not be able to reach
    /// `tabs.query`/`tabs.create` — the underlying handlers must not even run.
    func testTabsDeniedWithoutTabsPermission() throws {
        let (router, responder, extensionID) = try makeRouter(permissions: ["storage"])
        var queryHandlerCalled = false
        router.tabQueryHandler = { _ in
            queryHandlerCalled = true
            return []
        }
        router.handle(
            ExtensionBridgeCall(id: 1, method: "tabs.query", args: [["active": true]]), extensionID: extensionID)
        XCTAssertEqual(responder.responses.first?.success, false)
        XCTAssertEqual(responder.responses.first?.value as? String, "Missing permission: tabs")
        XCTAssertFalse(queryHandlerCalled, "tabs.query must not run its handler without the tabs permission")

        var createHandlerCalled = false
        router.tabCreateHandler = { _ in createHandlerCalled = true }
        router.handle(
            ExtensionBridgeCall(id: 2, method: "tabs.create", args: [["url": "https://qwave.app"]]),
            extensionID: extensionID)
        XCTAssertEqual(responder.responses.last?.success, false)
        XCTAssertFalse(createHandlerCalled, "tabs.create must not run its handler without the tabs permission")
    }

    /// The mirror case: declaring `tabs` grants access.
    func testTabsAllowedWithTabsPermission() throws {
        let (router, responder, extensionID) = try makeRouter(permissions: ["tabs"])
        router.tabQueryHandler = { _ in [["id": 1]] }
        router.handle(
            ExtensionBridgeCall(id: 1, method: "tabs.query", args: [["active": true]]), extensionID: extensionID)
        XCTAssertEqual(responder.responses.first?.success, true)
    }

    /// A caller identity that isn't an installed extension at all (the
    /// shared-bridge placeholder used when zero or multiple extensions are
    /// installed) has no permissions and is denied, never silently granted.
    func testUnknownExtensionIdentityIsDeniedGatedMethods() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("qwave-ext-router-\(UUID().uuidString)", isDirectory: true)
        let defaults = UserDefaults(suiteName: "qwave-test-router-\(UUID().uuidString)")!
        let router = ExtensionMessageRouter(
            registry: WebExtensionRegistry(defaults: defaults),
            storage: ExtensionStorageService(directory: dir)
        )
        let responder = RecordingResponder()
        router.responder = responder
        router.handle(
            ExtensionBridgeCall(id: 1, method: "storage.local.get", args: [NSNull()]), extensionID: "page")
        XCTAssertEqual(responder.responses.first?.success, false)
    }

    /// `runtime.sendMessage` is intentionally ungated — it must keep working
    /// even for an extension that declares no permissions at all.
    func testRuntimeMessagingIsUngated() throws {
        let (router, responder, extensionID) = try makeRouter(permissions: [])
        router.runtimeMessageHandler = { payload, reply in
            reply(payload)
        }
        router.handle(
            ExtensionBridgeCall(id: 1, method: "runtime.sendMessage", args: ["ping"]), extensionID: extensionID)
        XCTAssertEqual(responder.responses.first?.value as? String, "ping")
    }
}

/// Regression tests for the bridge's JS-literal encoder.
///
/// The old encoder called `JSONSerialization.data(withJSONObject:)` on the raw
/// value and hand-escaped only `"` when that failed. A bare string is not a
/// valid top-level JSON object, so every string payload hit that path — and on
/// Apple Foundation the serializer *raises* `NSInvalidArgumentException` rather
/// than returning an error, which `try?` cannot catch. Either way the value
/// reached `evaluateJavaScript` unsafely.
final class ExtensionJSLiteralTests: XCTestCase {
    /// Parses a JS literal back as a JSON fragment, proving nothing escaped the
    /// string and nothing was lost.
    private func roundTrip(_ literal: String) throws -> Any {
        try JSONSerialization.jsonObject(with: Data(literal.utf8), options: [.fragmentsAllowed])
    }

    func testBareStringPayloadsRoundTripAndCannotBreakOut() throws {
        let payloads = [
            #"back\slash"#,
            "new\nline",
            "carriage\rreturn",
            #"quote" and \" escaped quote"#,
            "line\u{2028}separator",
            "paragraph\u{2029}separator",
            #"\");alert(1);//"#,
            "</script><img src=x onerror=alert(1)>",
            "tab\tand\u{0000}nul",
        ]
        for payload in payloads {
            let literal = ExtensionJSLiteral.encode(payload)
            XCTAssertEqual(
                try roundTrip(literal) as? String, payload,
                "payload did not round-trip: \(payload.debugDescription)")
            // Nothing that terminates a JS string literal or statement may
            // survive raw in the spliced source.
            for raw in ["\n", "\r", "\u{2028}", "\u{2029}"] {
                XCTAssertFalse(
                    literal.contains(raw),
                    "raw line terminator survived encoding of \(payload.debugDescription)")
            }
            // The literal is exactly one quoted JS string: quotes only at the ends.
            XCTAssertTrue(literal.hasPrefix("\"") && literal.hasSuffix("\""))
        }
    }

    func testBackslashIsEscapedNotJustTheQuote() {
        // The old hand-escaper turned `a\"` into `a\\"`, which closes the JS
        // string early and leaves the rest of the payload as executable source.
        let literal = ExtensionJSLiteral.encode(#"a\"; alert(1); x"#)
        XCTAssertEqual(literal, #""a\\\"; alert(1); x""#)
    }

    func testStructuredValuesStillEncodeAsJSON() throws {
        let dict = ExtensionJSLiteral.encode(["theme": "dark", "zoom": 2])
        let decoded = try XCTUnwrap(try roundTrip(dict) as? [String: Any])
        XCTAssertEqual(decoded["theme"] as? String, "dark")
        XCTAssertEqual(decoded["zoom"] as? Int, 2)

        let array = ExtensionJSLiteral.encode([1, 2, 3])
        XCTAssertEqual(try roundTrip(array) as? [Int], [1, 2, 3])

        XCTAssertEqual(ExtensionJSLiteral.encode([:] as [String: Any]), "{}")
        XCTAssertEqual(ExtensionJSLiteral.encode(42), "42")
        XCTAssertEqual(ExtensionJSLiteral.encode(true), "true")
    }

    /// Values JSON cannot represent must degrade to `null`, not raise.
    func testNonSerializableValuesEncodeAsNull() {
        XCTAssertEqual(ExtensionJSLiteral.encode(nil), "null")
        XCTAssertEqual(ExtensionJSLiteral.encode(NSNull()), "null")
        XCTAssertEqual(ExtensionJSLiteral.encode(Date()), "null")
        XCTAssertEqual(ExtensionJSLiteral.encode(Double.nan), "null")
        XCTAssertEqual(ExtensionJSLiteral.encode(Double.infinity), "null")
    }
}

@MainActor
final class ExtensionBridgeInstallationTests: XCTestCase {
    private func makeHost() -> WebExtensionHost {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("qwave-ext-host-\(UUID().uuidString)", isDirectory: true)
        let defaults = UserDefaults(suiteName: "qwave-test-host-\(UUID().uuidString)")!
        return WebExtensionHost(storageDirectory: dir, defaults: defaults)
    }

    private func makeExtensionBundle() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("qwave-ext-bundle-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try #"{ "name": "Bridge Ext", "version": "1.0", "manifest_version": 3 }"#
            .write(to: dir.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
        return dir
    }

    /// With nothing installed, a page must not see the bridge at all.
    func testBridgeIsNotInstalledWhenNoExtensionsArePresent() {
        let host = makeHost()
        let controller = WKUserContentController()
        host.installBridge(into: controller)
        XCTAssertTrue(controller.userScripts.isEmpty)
    }

    func testBridgeIsInstalledOnceAnExtensionExists() throws {
        let host = makeHost()
        _ = try host.install(bundleDirectory: try makeExtensionBundle())
        let controller = WKUserContentController()
        host.installBridge(into: controller)
        XCTAssertEqual(controller.userScripts.count, 1)
        XCTAssertTrue(controller.userScripts[0].source.contains("__qwaveNative"))
    }

    /// The bridge and content scripts must not share the page's JS world.
    func testExtensionContentWorldIsIsolatedFromThePage() {
        XCTAssertEqual(ExtensionContentWorld.isolated.name, "QwaveExtensions")
        XCTAssertNotEqual(ExtensionContentWorld.isolated, WKContentWorld.page)
    }
}

final class DeclarativeNetRequestTests: XCTestCase {
    func testDecodeDNRRuleAndCompileToWebKitJSON() throws {
        let ruleJSON = """
            {
              "id": 1,
              "priority": 1,
              "action": { "type": "block" },
              "condition": {
                "url_filter": "||adserver.example.com",
                "resource_types": ["script", "image"]
              }
            }
            """
        let rule = try JSONDecoder().decode(DNRRule.self, from: Data(ruleJSON.utf8))
        XCTAssertEqual(rule.id, 1)
        XCTAssertEqual(rule.action.type, .block)
        XCTAssertEqual(rule.condition.urlFilter, "||adserver.example.com")
        XCTAssertEqual(rule.condition.resourceTypes, ["script", "image"])

        let compiledJSON = try DeclarativeNetRequestConverter.convertToWebKitRulesJSON([rule])
        XCTAssertTrue(compiledJSON.contains("adserver"))
        XCTAssertTrue(compiledJSON.contains("example"))
        XCTAssertTrue(compiledJSON.contains("\"type\" : \"block\""))
        XCTAssertTrue(compiledJSON.contains("\"script\""))
        XCTAssertTrue(compiledJSON.contains("\"image\""))
    }

    /// Regression test for #73: `redirect` rules must not be silently
    /// reinterpreted as `block`. WKContentRuleList has no redirect action,
    /// so the rule should be dropped from the compiled output entirely
    /// rather than emitted with `"type": "block"`.
    func testRedirectRuleIsDroppedNotSilentlyBlocked() throws {
        let ruleJSON = """
            {
              "id": 7,
              "action": {
                "type": "redirect",
                "redirect": { "url": "https://example.com/stub.js" }
              },
              "condition": { "url_filter": "||tracker.example.com" }
            }
            """
        let rule = try JSONDecoder().decode(DNRRule.self, from: Data(ruleJSON.utf8))
        XCTAssertEqual(rule.action.type, .redirect)
        XCTAssertEqual(rule.action.redirect?.url, "https://example.com/stub.js")

        let compiledJSON = try DeclarativeNetRequestConverter.convertToWebKitRulesJSON([rule])
        let decoded = try JSONSerialization.jsonObject(with: Data(compiledJSON.utf8)) as? [[String: Any]]
        XCTAssertEqual(decoded?.count, 0, "redirect rule must be dropped, not compiled as a trigger/action pair")
        XCTAssertFalse(compiledJSON.contains("\"block\""), "a dropped redirect rule must never surface as 'block'")
    }

    /// A `redirect` rule sitting alongside supported rules should only drop
    /// itself — the other rules must still compile normally.
    func testRedirectRuleDoesNotAffectOtherRulesInTheSameList() throws {
        let blockJSON = """
            {
              "id": 1,
              "action": { "type": "block" },
              "condition": { "url_filter": "||ads.example.com" }
            }
            """
        let redirectJSON = """
            {
              "id": 2,
              "action": { "type": "redirect", "redirect": { "url": "https://example.com/stub" } },
              "condition": { "url_filter": "||tracker.example.com" }
            }
            """
        let allowJSON = """
            {
              "id": 3,
              "action": { "type": "allow" },
              "condition": { "url_filter": "||safe.example.com" }
            }
            """
        let rules = try [blockJSON, redirectJSON, allowJSON].map {
            try JSONDecoder().decode(DNRRule.self, from: Data($0.utf8))
        }

        let compiledJSON = try DeclarativeNetRequestConverter.convertToWebKitRulesJSON(rules)
        let decoded = try JSONSerialization.jsonObject(with: Data(compiledJSON.utf8)) as? [[String: Any]]
        XCTAssertEqual(decoded?.count, 2, "only the block and allow rules should survive compilation")
        XCTAssertTrue(compiledJSON.contains("ads"))
        XCTAssertTrue(compiledJSON.contains("safe"))
        XCTAssertTrue(compiledJSON.contains("\"ignore-previous-rules\""))
        XCTAssertFalse(compiledJSON.contains("tracker"))
    }
}

final class BrowserBridgeScriptTests: XCTestCase {
    func testBridgeSurface() {
        let source = BrowserBridgeScript.source
        XCTAssertTrue(source.contains("runtime.sendMessage"))
        XCTAssertTrue(source.contains("onMessage"))
        XCTAssertTrue(source.contains("addListener"))
        XCTAssertTrue(source.contains("removeListener"))
        XCTAssertTrue(source.contains("hasListener"))
        XCTAssertTrue(source.contains("dispatchMessage(message, sender, messageId)"))
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
