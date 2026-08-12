import Foundation

/// URLProtocol mock: tests register handlers per path; no live network ever.
final class MockURLProtocol: URLProtocol {
    struct Stub {
        let status: Int
        let body: Data
        /// Captures the request for assertions.
        let onRequest: ((URLRequest) -> Void)?
    }

    nonisolated(unsafe) static var stubs: [String: Stub] = [:]
    private static let lock = NSLock()

    static func stub(path: String, status: Int = 200, json: String, onRequest: ((URLRequest) -> Void)? = nil) {
        lock.lock()
        defer { lock.unlock() }
        stubs[path] = Stub(status: status, body: Data(json.utf8), onRequest: onRequest)
    }

    static func reset() {
        lock.lock()
        defer { lock.unlock() }
        stubs = [:]
    }

    private static func stub(for path: String) -> Stub? {
        lock.lock()
        defer { lock.unlock() }
        return stubs[path]
    }

    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let path = request.url?.path ?? ""
        guard let stub = Self.stub(for: path) else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        stub.onRequest?(request)
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: stub.status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: stub.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
