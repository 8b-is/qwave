import XCTest
@testable import VPNKit

private extension URLRequest {
    /// URLProtocol turns httpBody into a stream; drain it for assertions.
    var bodyData: Data? {
        if let httpBody { return httpBody }
        guard let stream = httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 4096
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: bufferSize)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}

/// Reference box so stub callbacks (which run on URLSession's queues) can
/// hand the captured request back to the test.
private final class RequestBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _request: URLRequest?

    var request: URLRequest? {
        get { lock.lock(); defer { lock.unlock() }; return _request }
        set { lock.lock(); defer { lock.unlock() }; _request = newValue }
    }
}

final class MullvadAPIClientTests: XCTestCase {
    private var client: MullvadAPIClient!

    override func setUp() {
        super.setUp()
        MockURLProtocol.reset()
        client = MullvadAPIClient(session: MockURLProtocol.makeSession())
    }

    override func tearDown() {
        MockURLProtocol.reset()
        super.tearDown()
    }

    func testObtainAccessToken() async throws {
        let box = RequestBox()
        MockURLProtocol.stub(
            path: "/auth/v1/token",
            json: #"{"access_token": "mva_abc123", "expiry": "2026-09-01T12:00:00+00:00"}"#,
            onRequest: { box.request = $0 }
        )

        let token = try await client.obtainAccessToken(accountNumber: "1234 5678 9012 3456")
        XCTAssertEqual(token.accessToken, "mva_abc123")

        let request = try XCTUnwrap(box.request)
        XCTAssertEqual(request.httpMethod, "POST")
        let body = try JSONSerialization.jsonObject(with: XCTUnwrap(request.bodyData)) as? [String: Any]
        XCTAssertEqual(body?["account_number"] as? String, "1234567890123456", "spaces must be stripped")
    }

    func testRejectsGarbageAccountNumberLocally() async {
        do {
            _ = try await client.obtainAccessToken(accountNumber: "not-a-number")
            XCTFail("expected error")
        } catch {
            XCTAssertEqual(error as? MullvadAPIError, .invalidAccountNumber)
        }
    }

    func testRegisterDeviceSendsBearerAndPubkey() async throws {
        let box = RequestBox()
        MockURLProtocol.stub(
            path: "/accounts/v1/devices",
            status: 201,
            json: """
                {"id": "dev-1", "name": "cuddly krill", "pubkey": "AAA=",
                 "ipv4_address": "10.67.1.2/32", "ipv6_address": "fc00:bbbb::2/128"}
                """,
            onRequest: { box.request = $0 }
        )

        let device = try await client.registerDevice(accessToken: "mva_token", publicKeyBase64: "AAA=")
        XCTAssertEqual(device.id, "dev-1")
        XCTAssertEqual(device.ipv4Address, "10.67.1.2/32")

        let request = try XCTUnwrap(box.request)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer mva_token")
        let body = try JSONSerialization.jsonObject(with: XCTUnwrap(request.bodyData)) as? [String: Any]
        XCTAssertEqual(body?["pubkey"] as? String, "AAA=")
    }

    func testHTTPErrorSurfaces() async {
        MockURLProtocol.stub(path: "/auth/v1/token", status: 401, json: #"{"code": "INVALID_ACCOUNT"}"#)
        do {
            _ = try await client.obtainAccessToken(accountNumber: "1234567890123456")
            XCTFail("expected error")
        } catch let MullvadAPIError.httpError(status, _) {
            XCTAssertEqual(status, 401)
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testRelayListDecodesFixture() async throws {
        let fixtureURL = try XCTUnwrap(Bundle.module.url(forResource: "relays", withExtension: "json"))
        let fixture = try String(contentsOf: fixtureURL, encoding: .utf8)
        MockURLProtocol.stub(path: "/app/v1/relays", json: fixture)

        let list = try await client.relayList()
        XCTAssertEqual(list.wireguard.relays.count, 3)
        XCTAssertEqual(list.locations["se-sto"]?.country, "Sweden")
        XCTAssertEqual(list.wireguard.ipv4Gateway, "10.64.0.1")
        XCTAssertTrue(list.wireguard.portRanges.contains([53, 53]))
    }
}
