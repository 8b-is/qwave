import AVFoundation
import Shields
import WebKit
import XCTest

@testable import BrowserCore

@MainActor
final class WebPermissionLifecycleTests: XCTestCase {
    private let origin = WebPermissionOrigin(scheme: "https", host: "permission-fixture.invalid", port: 0)

    private func key(_ container: UUID?, _ permission: WebPermission = .location) -> WebPermissionKey {
        WebPermissionKey(containerID: container, origin: origin, permission: permission)
    }

    private func coordinator(_ tab: Tab, store: WebPermissionStore) -> NavigationCoordinator {
        NavigationCoordinator(
            tab: tab,
            shields: ShieldsDirector(compiler: RuleListCompiler(), policy: ShieldsPolicy(directory: nil)),
            httpsUpgrader: HTTPSFirstUpgrader(), history: nil,
            downloads: DownloadManager(directory: FileManager.default.temporaryDirectory), permissions: store)
    }

    private func webView(persistent: Bool = false) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = persistent ? .default() : .nonPersistent()
        return WKWebView(frame: .zero, configuration: configuration)
    }

    private func frame(in webView: WKWebView) async throws -> WKFrameInfo {
        let sink = PermissionLifecycleFrameSink()
        let controller = webView.configuration.userContentController
        controller.add(sink, name: "fixture")
        defer { controller.removeScriptMessageHandler(forName: "fixture") }
        webView.loadHTMLString(
            "<html><script>window.webkit.messageHandlers.fixture.postMessage('ready')</script></html>",
            baseURL: URL(string: "https://permission-fixture.invalid/"))
        let deadline = Date().addingTimeInterval(10)
        while sink.frame == nil && Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let frame = try XCTUnwrap(sink.frame, "Local inline WebKit frame did not load")
        XCTAssertEqual(WebPermissionOrigin(frame.securityOrigin), origin)
        return frame
    }

    func testPrivateCallbacksDoNotShareChoicesAcrossTabs() async throws {
        let shared = WebPermissionStore()
        let id = ContainerRegistry.ephemeralProfileID
        let a = webView(), b = webView()
        let tabA = Tab(containerID: id, isEphemeral: true)
        let tabB = Tab(containerID: id, isEphemeral: true)
        tabA.attach(webView: a)
        tabB.attach(webView: b)
        let first = coordinator(tabA, store: shared), second = coordinator(tabB, store: shared)
        // Obtain the synthetic frame before attaching the navigation/shields gate.
        let frame = try await frame(in: a)
        first.attach(to: a)
        second.attach(to: b)
        defer { first.detach(); second.detach(); a.stopLoading(); b.stopLoading() }
        let storeA = try XCTUnwrap(first.permissionStore(for: a))
        let storeB = try XCTUnwrap(second.permissionStore(for: b))
        XCTAssertFalse(storeA === storeB)
        XCTAssertFalse(storeA === shared)
        for permission in WebPermission.allCases {
            storeA.record(.allow, for: key(id, permission))
            XCTAssertNil(storeB.decision(for: key(id, permission)))
            XCTAssertNil(shared.decision(for: key(id, permission)))
        }
        // Opposite synthetic choices exercise the actual callback routing
        // without a real user prompt, location request or capture device.
        storeB.record(.deny, for: key(id))
        storeB.record(.deny, for: key(id, .camera))
        let allowed = expectation(description: "first tab location allowed")
        first.webView(a, requestGeolocationPermissionFor: frame.securityOrigin, initiatedByFrame: frame) {
            XCTAssertEqual($0, .grant); allowed.fulfill()
        }
        let denied = expectation(description: "second tab location denied")
        second.webView(b, requestGeolocationPermissionFor: frame.securityOrigin, initiatedByFrame: frame) {
            XCTAssertEqual($0, .deny); denied.fulfill()
        }
        let camera = expectation(description: "second tab camera denied")
        second.webView(
            b, requestMediaCapturePermissionFor: frame.securityOrigin, initiatedByFrame: frame, type: .camera
        ) {
            XCTAssertEqual($0, .deny); camera.fulfill()
        }
        await fulfillment(of: [allowed, denied, camera], timeout: 2)
        first.detach()
        let closedLocation = expectation(description: "detached location denied")
        first.webView(a, requestGeolocationPermissionFor: frame.securityOrigin, initiatedByFrame: frame) {
            XCTAssertEqual($0, .deny); closedLocation.fulfill()
        }
        let closedCamera = expectation(description: "detached camera denied without device access")
        first.webView(a, requestMediaCapturePermissionFor: frame.securityOrigin, initiatedByFrame: frame, type: .camera)
        {
            XCTAssertEqual($0, .deny); closedCamera.fulfill()
        }
        await fulfillment(of: [closedLocation, closedCamera], timeout: 2)
    }

    func testNonpersistentStoreIsIsolatedEvenWithoutEphemeralFlag() throws {
        let shared = WebPermissionStore()
        let tab = Tab(containerID: UUID())
        let view = webView()
        tab.attach(webView: view)
        let coordinator = coordinator(tab, store: shared)
        coordinator.attach(to: view)
        defer { coordinator.detach() }
        XCTAssertFalse(try XCTUnwrap(coordinator.permissionStore(for: view)) === shared)
    }

    func testDetachAndReplacementForgetPrivateChoicesAndRejectOldViews() throws {
        let shared = WebPermissionStore()
        let tab = Tab(containerID: ContainerRegistry.ephemeralProfileID, isEphemeral: true)
        let first = webView(), replacement = webView()
        let coordinator = coordinator(tab, store: shared)
        tab.attach(webView: first)
        coordinator.attach(to: first)
        defer { coordinator.detach() }
        let privateStore = try XCTUnwrap(coordinator.permissionStore(for: first))
        privateStore.record(.allow, for: key(tab.containerID))
        coordinator.detach()
        XCTAssertNil(privateStore.decision(for: key(tab.containerID)))
        XCTAssertNil(coordinator.permissionStore(for: first))
        coordinator.attach(to: first)
        privateStore.record(.allow, for: key(tab.containerID))
        // Hibernation restore replaces the web view while retaining the Tab.
        tab.attach(webView: replacement)
        coordinator.attach(to: replacement)
        XCTAssertNil(privateStore.decision(for: key(tab.containerID)))
        XCTAssertNil(coordinator.permissionStore(for: first))
        XCTAssertNotNil(coordinator.permissionStore(for: replacement))
        tab.markFresh()
        XCTAssertNil(coordinator.permissionStore(for: replacement))
    }

    func testPersistentTabsRetainSharedContainerChoicesAfterDetach() throws {
        let shared = WebPermissionStore()
        let container = UUID()
        let tabA = Tab(containerID: container), tabB = Tab(containerID: container)
        let a = webView(persistent: true), b = webView(persistent: true)
        tabA.attach(webView: a); tabB.attach(webView: b)
        let first = coordinator(tabA, store: shared), second = coordinator(tabB, store: shared)
        first.attach(to: a); second.attach(to: b)
        defer { first.detach(); second.detach() }
        XCTAssertTrue(try XCTUnwrap(first.permissionStore(for: a)) === shared)
        XCTAssertTrue(try XCTUnwrap(second.permissionStore(for: b)) === shared)
        shared.record(.allow, for: key(container))
        first.detach()
        XCTAssertEqual(second.permissionStore(for: b)?.decision(for: key(container)), .allow)
        XCTAssertNil(shared.decision(for: key(UUID())))
    }

    func testDeletingContainerInvalidatesOnlyItsPermissions() async {
        let store = WebPermissionStore()
        let registry = ContainerRegistry(directory: nil, permissions: store)
        let removed = registry.createProfile(name: "Disposable test profile", colorHex: "#000000")
        let retained = registry.createProfile(name: "Control test profile", colorHex: "#FFFFFF")
        for id in [Optional(removed.id), Optional(retained.id), nil] {
            for permission in WebPermission.allCases { store.record(.allow, for: key(id, permission)) }
        }
        // Initialize WebKit's run loop before asynchronous store removal.
        let keeper = webView()
        defer { keeper.stopLoading() }
        await registry.deleteProfile(id: removed.id)
        XCTAssertNil(registry.profile(withID: removed.id))
        XCTAssertNotNil(registry.profile(withID: retained.id))
        for permission in WebPermission.allCases {
            XCTAssertNil(store.decision(for: key(removed.id, permission)))
            XCTAssertEqual(store.decision(for: key(retained.id, permission)), .allow)
            XCTAssertEqual(store.decision(for: key(nil, permission)), .allow)
        }
    }

    func testResetBeforeQueuedMediaRequestPreventsPromptAndCapture() async {
        let store = WebPermissionStore()
        let id = UUID()
        let done = expectation(description: "invalidated media denied")
        let environment = WebPermissionArbiter.Environment(
            prompt: { _, _ in
                XCTFail("Must not prompt after reset"); return true
            },
            captureAccess: { _ in
                XCTFail("Must not request device access"); return true
            })
        WebPermissionArbiter.decideMediaCapture(
            origin: origin, type: .camera, containerID: id, store: store, environment: environment
        ) {
            XCTAssertEqual($0, .deny); done.fulfill()
        }
        store.reset(containerID: id)
        await fulfillment(of: [done], timeout: 2)
        XCTAssertNil(store.decision(for: key(id, .camera)))
    }

    func testDeletingContainerAlsoInvalidatesItsNonpersistentTabs() async throws {
        let shared = WebPermissionStore()
        let registry = ContainerRegistry(directory: nil, permissions: shared)
        let removed = registry.createProfile(name: "Disposable test profile", colorHex: "#000000")
        let retained = registry.createProfile(name: "Control test profile", colorHex: "#FFFFFF")
        let a = webView(), b = webView()
        let tabA = Tab(containerID: removed.id), tabB = Tab(containerID: retained.id)
        tabA.attach(webView: a); tabB.attach(webView: b)
        let first = coordinator(tabA, store: shared), second = coordinator(tabB, store: shared)
        first.attach(to: a); second.attach(to: b)
        defer { first.detach(); second.detach() }
        let privateA = try XCTUnwrap(first.permissionStore(for: a))
        let privateB = try XCTUnwrap(second.permissionStore(for: b))
        privateA.record(.allow, for: key(removed.id))
        privateB.record(.allow, for: key(retained.id))
        await registry.deleteProfile(id: removed.id)
        XCTAssertNil(privateA.decision(for: key(removed.id)))
        XCTAssertEqual(privateB.decision(for: key(retained.id)), .allow)
    }

    func testParentInvalidationCancelsPendingPrivateCapture() async {
        let shared = WebPermissionStore()
        let id = UUID()
        let privateStore = WebPermissionStore(invalidationSource: shared, containerID: id)
        let done = expectation(description: "deleted container private capture denied")
        let environment = WebPermissionArbiter.Environment(
            prompt: { _, _ in true },
            captureAccess: { _ in
                await Task.yield()
                shared.reset(containerID: id)
                return true
            })
        WebPermissionArbiter.decideMediaCapture(
            origin: origin, type: .camera, containerID: id, store: privateStore, environment: environment
        ) {
            XCTAssertEqual($0, .deny); done.fulfill()
        }
        await fulfillment(of: [done], timeout: 2)
        XCTAssertNil(privateStore.decision(for: key(id, .camera)))
    }

    func testResetDuringMediaPromptCannotRestoreConsent() async {
        let store = WebPermissionStore()
        let id = UUID()
        let done = expectation(description: "invalidated prompt denied")
        let environment = WebPermissionArbiter.Environment(
            prompt: { _, _ in
                store.reset(containerID: id); return true
            },
            captureAccess: { _ in
                XCTFail("Must not request access after reset"); return true
            })
        WebPermissionArbiter.decideMediaCapture(
            origin: origin, type: .cameraAndMicrophone, containerID: id, store: store, environment: environment
        ) {
            XCTAssertEqual($0, .deny); done.fulfill()
        }
        await fulfillment(of: [done], timeout: 2)
        XCTAssertNil(store.decision(for: key(id, .camera)))
        XCTAssertNil(store.decision(for: key(id, .microphone)))
    }

    func testResetWhileCameraAccessAwaitsPreventsMicrophoneAndGrant() async {
        let store = WebPermissionStore()
        let id = UUID()
        let done = expectation(description: "stale device result denied")
        let environment = WebPermissionArbiter.Environment(
            prompt: { _, _ in true },
            captureAccess: { media in
                XCTAssertEqual(media, .video, "No microphone request after invalidation")
                await Task.yield()
                store.reset(containerID: id)
                return true
            })
        WebPermissionArbiter.decideMediaCapture(
            origin: origin, type: .cameraAndMicrophone, containerID: id, store: store, environment: environment
        ) {
            XCTAssertEqual($0, .deny); done.fulfill()
        }
        await fulfillment(of: [done], timeout: 2)
        XCTAssertNil(store.decision(for: key(id, .camera)))
    }

    func testResetBeforeQueuedLocationRequestPreventsPrompt() async {
        let store = WebPermissionStore()
        let done = expectation(description: "invalidated location denied")
        let environment = WebPermissionArbiter.Environment(
            prompt: { _, _ in
                XCTFail("Must not prompt after reset"); return true
            }, captureAccess: { _ in false })
        WebPermissionArbiter.decideGeolocation(
            origin: origin, containerID: nil, store: store, environment: environment
        ) {
            XCTAssertEqual($0, .deny); done.fulfill()
        }
        store.reset(containerID: nil)
        await fulfillment(of: [done], timeout: 2)
        XCTAssertNil(store.decision(for: key(nil)))
    }

    func testResetDuringLocationPromptCannotRestoreConsent() async {
        for resetAll in [false, true] {
            let store = WebPermissionStore()
            let id = UUID()
            let done = expectation(description: "invalidated location prompt denied")
            let environment = WebPermissionArbiter.Environment(
                prompt: { _, _ in
                    if resetAll { store.reset() } else { store.reset(containerID: id) }
                    return true
                }, captureAccess: { _ in false })
            WebPermissionArbiter.decideGeolocation(
                origin: origin, containerID: id, store: store, environment: environment
            ) {
                XCTAssertEqual($0, .deny); done.fulfill()
            }
            await fulfillment(of: [done], timeout: 2)
            XCTAssertNil(store.decision(for: key(id)))
        }
    }

    func testUnrelatedContainerResetDoesNotCancelPrompt() async {
        let store = WebPermissionStore()
        let id = UUID(), other = UUID()
        store.record(.allow, for: key(other))
        let done = expectation(description: "unrelated container remains allowed")
        let environment = WebPermissionArbiter.Environment(
            prompt: { _, _ in
                store.reset(containerID: other); return true
            }, captureAccess: { _ in false })
        WebPermissionArbiter.decideGeolocation(
            origin: origin, containerID: id, store: store, environment: environment
        ) {
            XCTAssertEqual($0, .grant); done.fulfill()
        }
        await fulfillment(of: [done], timeout: 2)
        XCTAssertEqual(store.decision(for: key(id)), .allow)
        XCTAssertNil(store.decision(for: key(other)))
    }
}

@MainActor
private final class PermissionLifecycleFrameSink: NSObject, WKScriptMessageHandler {
    var frame: WKFrameInfo?
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        frame = message.frameInfo
    }
}
