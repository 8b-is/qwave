import WebKit
import XCTest

@testable import BrowserCore

@MainActor
final class WebPermissionsTests: XCTestCase {
    func testRememberedChoicesDoNotCrossSchemesOrPorts() {
        let original = WebPermissionOrigin(scheme: "https", host: "example.com", port: 8443)
        let others = [
            WebPermissionOrigin(scheme: "http", host: "example.com", port: 8443),
            WebPermissionOrigin(scheme: "https", host: "example.com", port: 9443),
            WebPermissionOrigin(scheme: "https", host: "example.com", port: 0),
        ]
        for permission in WebPermission.allCases {
            for decision in [WebPermissionDecision.allow, .deny] {
                let store = WebPermissionStore()
                let key = WebPermissionKey(containerID: nil, origin: original, permission: permission)
                store.record(decision, for: key)
                XCTAssertEqual(store.decision(for: key), decision)
                for other in others {
                    let otherKey = WebPermissionKey(containerID: nil, origin: other, permission: permission)
                    XCTAssertNil(store.decision(for: otherKey), "\(permission): \(original) must not share \(decision) with \(other)")
                }
            }
        }
    }

    func testDefaultPortsAndCaseReferToSameOrigin() {
        for (scheme, port) in [("http", 80), ("https", 443)] {
            let store = WebPermissionStore()
            let implicit = WebPermissionKey(
                containerID: nil,
                origin: WebPermissionOrigin(scheme: scheme.uppercased(), host: "EXAMPLE.COM", port: 0),
                permission: .camera)
            let explicit = WebPermissionKey(
                containerID: nil,
                origin: WebPermissionOrigin(scheme: scheme, host: "example.com", port: port),
                permission: .camera)
            store.record(.deny, for: implicit)
            XCTAssertEqual(store.decision(for: explicit), .deny)
        }
    }

    func testPromptIdentifiesSchemeAndNonstandardPort() {
        XCTAssertEqual(WebPermissionOrigin(scheme: "https", host: "example.com", port: 0).displayName, "https://example.com")
        XCTAssertEqual(WebPermissionOrigin(scheme: "http", host: "example.com", port: 8443).displayName, "http://example.com:8443")
        XCTAssertEqual(WebPermissionOrigin(scheme: "https", host: "::1", port: 9443).displayName, "https://[::1]:9443")
        XCTAssertEqual(WebPermissionOrigin(scheme: "https", host: "[::1]", port: 9443).displayName, "https://[::1]:9443")
    }

    func testInvalidOriginsDeniedEvenWithCachedAllow() {
        let origins = [
            WebPermissionOrigin(scheme: "", host: "example.com", port: 443),
            WebPermissionOrigin(scheme: "https", host: "", port: 443),
            WebPermissionOrigin(scheme: "https", host: "example.com", port: -1),
            WebPermissionOrigin(scheme: "https", host: "example.com", port: 65536),
        ]
        for origin in origins {
            let store = WebPermissionStore()
            for permission in WebPermission.allCases {
                store.record(.allow, for: WebPermissionKey(containerID: nil, origin: origin, permission: permission))
            }
            let media = expectation(description: "invalid media origin")
            WebPermissionArbiter.decideMediaCapture(origin: origin, type: .cameraAndMicrophone, containerID: nil, store: store) {
                XCTAssertEqual($0, .deny)
                media.fulfill()
            }
            let location = expectation(description: "invalid location origin")
            WebPermissionArbiter.decideGeolocation(origin: origin, containerID: nil, store: store) {
                XCTAssertEqual($0, .deny)
                location.fulfill()
            }
            wait(for: [media, location], timeout: 1)
        }
    }

    func testGeolocationUsesDecisionForCompleteOrigin() {
        let origin = WebPermissionOrigin(scheme: "https", host: "example.com", port: 8443)
        for other in [
            WebPermissionOrigin(scheme: "http", host: "example.com", port: 8443),
            WebPermissionOrigin(scheme: "https", host: "example.com", port: 9443),
        ] {
            let store = WebPermissionStore()
            store.record(.allow, for: WebPermissionKey(containerID: nil, origin: origin, permission: .location))
            store.record(.deny, for: WebPermissionKey(containerID: nil, origin: other, permission: .location))
            let allowed = expectation(description: "same origin allowed")
            WebPermissionArbiter.decideGeolocation(origin: origin, containerID: nil, store: store) {
                XCTAssertEqual($0, .grant)
                allowed.fulfill()
            }
            let denied = expectation(description: "other origin denied")
            WebPermissionArbiter.decideGeolocation(origin: other, containerID: nil, store: store) {
                XCTAssertEqual($0, .deny)
                denied.fulfill()
            }
            wait(for: [allowed, denied], timeout: 1)
        }
    }

    func testKeyLowercasesHostForStableMatching() {
        let a = WebPermissionKey(containerID: nil, origin: WebPermissionOrigin(scheme: "https", host: "Meet.Google.COM", port: 443), permission: .camera)
        let b = WebPermissionKey(containerID: nil, origin: WebPermissionOrigin(scheme: "https", host: "meet.google.com", port: 443), permission: .camera)
        XCTAssertEqual(a, b)
    }

    func testKeyDistinguishesPermissionAndHost() {
        let cam = WebPermissionKey(containerID: nil, origin: WebPermissionOrigin(scheme: "https", host: "example.com", port: 443), permission: .camera)
        let mic = WebPermissionKey(containerID: nil, origin: WebPermissionOrigin(scheme: "https", host: "example.com", port: 443), permission: .microphone)
        let other = WebPermissionKey(containerID: nil, origin: WebPermissionOrigin(scheme: "https", host: "other.com", port: 443), permission: .camera)
        XCTAssertNotEqual(cam, mic)
        XCTAssertNotEqual(cam, other)
    }

    func testDecisionsAreIsolatedPerContainer() {
        let store = WebPermissionStore()
        let personal = UUID()
        let work = UUID()
        let inPersonal = WebPermissionKey(containerID: personal, origin: WebPermissionOrigin(scheme: "https", host: "example.com", port: 443), permission: .camera)
        let inWork = WebPermissionKey(containerID: work, origin: WebPermissionOrigin(scheme: "https", host: "example.com", port: 443), permission: .camera)
        let inDefault = WebPermissionKey(containerID: nil, origin: WebPermissionOrigin(scheme: "https", host: "example.com", port: 443), permission: .camera)

        store.record(.allow, for: inPersonal)

        XCTAssertEqual(store.decision(for: inPersonal), .allow)
        // A grant in one container must not leak into another, nor the default space.
        XCTAssertNil(store.decision(for: inWork))
        XCTAssertNil(store.decision(for: inDefault))
    }

    func testRecordOverwritesAndResetClears() {
        let store = WebPermissionStore()
        let key = WebPermissionKey(containerID: nil, origin: WebPermissionOrigin(scheme: "https", host: "example.com", port: 443), permission: .location)
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
            origin: WebPermissionOrigin(scheme: "https", host: "", port: 443), type: .cameraAndMicrophone, containerID: nil, store: store
        ) { decision in
            XCTAssertEqual(decision, .deny)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1)
    }

    func testRememberedDenyShortCircuitsToDeny() {
        let store = WebPermissionStore()
        store.record(.deny, for: WebPermissionKey(containerID: nil, origin: WebPermissionOrigin(scheme: "https", host: "example.com", port: 443), permission: .camera))
        let exp = expectation(description: "decision")
        // Camera already denied -> the whole camera+mic request is denied without a prompt.
        WebPermissionArbiter.decideMediaCapture(
            origin: WebPermissionOrigin(scheme: "https", host: "example.com", port: 443), type: .cameraAndMicrophone, containerID: nil, store: store
        ) { decision in
            XCTAssertEqual(decision, .deny)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1)
    }

    func testRememberedGeolocationDenyReturnsDeny() {
        let store = WebPermissionStore()
        store.record(.deny, for: WebPermissionKey(containerID: nil, origin: WebPermissionOrigin(scheme: "https", host: "example.com", port: 443), permission: .location))
        let exp = expectation(description: "decision")
        WebPermissionArbiter.decideGeolocation(origin: WebPermissionOrigin(scheme: "https", host: "example.com", port: 443), containerID: nil, store: store) { decision in
            XCTAssertEqual(decision, .deny)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1)
    }
}
