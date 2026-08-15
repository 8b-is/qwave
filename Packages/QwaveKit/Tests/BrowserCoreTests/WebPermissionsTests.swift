import WebKit
import XCTest

@testable import BrowserCore

@MainActor
final class WebPermissionsTests: XCTestCase {
    func testKeyLowercasesHostForStableMatching() {
        let a = WebPermissionKey(containerID: nil, originHost: "Meet.Google.COM", permission: .camera)
        let b = WebPermissionKey(containerID: nil, originHost: "meet.google.com", permission: .camera)
        XCTAssertEqual(a, b)
    }

    func testKeyDistinguishesPermissionAndHost() {
        let cam = WebPermissionKey(containerID: nil, originHost: "example.com", permission: .camera)
        let mic = WebPermissionKey(containerID: nil, originHost: "example.com", permission: .microphone)
        let other = WebPermissionKey(containerID: nil, originHost: "other.com", permission: .camera)
        XCTAssertNotEqual(cam, mic)
        XCTAssertNotEqual(cam, other)
    }

    func testDecisionsAreIsolatedPerContainer() {
        let store = WebPermissionStore()
        let personal = UUID()
        let work = UUID()
        let inPersonal = WebPermissionKey(containerID: personal, originHost: "example.com", permission: .camera)
        let inWork = WebPermissionKey(containerID: work, originHost: "example.com", permission: .camera)
        let inDefault = WebPermissionKey(containerID: nil, originHost: "example.com", permission: .camera)

        store.record(.allow, for: inPersonal)

        XCTAssertEqual(store.decision(for: inPersonal), .allow)
        // A grant in one container must not leak into another, nor the default space.
        XCTAssertNil(store.decision(for: inWork))
        XCTAssertNil(store.decision(for: inDefault))
    }

    func testRecordOverwritesAndResetClears() {
        let store = WebPermissionStore()
        let key = WebPermissionKey(containerID: nil, originHost: "example.com", permission: .location)
        store.record(.allow, for: key)
        XCTAssertEqual(store.decision(for: key), .allow)
        store.record(.deny, for: key)
        XCTAssertEqual(store.decision(for: key), .deny)
        store.reset()
        XCTAssertNil(store.decision(for: key))
    }

    func testMediaCaptureTypeMapping() {
        XCTAssertEqual(WebPermissionArbiter.permissions(for: .camera), [.camera])
        XCTAssertEqual(WebPermissionArbiter.permissions(for: .microphone), [.microphone])
        XCTAssertEqual(WebPermissionArbiter.permissions(for: .cameraAndMicrophone), [.camera, .microphone])
    }

    func testEmptyHostIsDeniedWithoutPrompting() {
        let store = WebPermissionStore()
        let exp = expectation(description: "decision")
        WebPermissionArbiter.decideMediaCapture(
            host: "", type: .cameraAndMicrophone, containerID: nil, store: store
        ) { decision in
            XCTAssertEqual(decision, .deny)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1)
    }

    func testRememberedDenyShortCircuitsToDeny() {
        let store = WebPermissionStore()
        store.record(.deny, for: WebPermissionKey(containerID: nil, originHost: "example.com", permission: .camera))
        let exp = expectation(description: "decision")
        // Camera already denied -> the whole camera+mic request is denied without a prompt.
        WebPermissionArbiter.decideMediaCapture(
            host: "example.com", type: .cameraAndMicrophone, containerID: nil, store: store
        ) { decision in
            XCTAssertEqual(decision, .deny)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1)
    }

    func testRememberedGeolocationDenyReturnsDeny() {
        let store = WebPermissionStore()
        store.record(.deny, for: WebPermissionKey(containerID: nil, originHost: "example.com", permission: .location))
        let exp = expectation(description: "decision")
        WebPermissionArbiter.decideGeolocation(host: "example.com", containerID: nil, store: store) { decision in
            XCTAssertEqual(decision, .deny)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1)
    }
}
