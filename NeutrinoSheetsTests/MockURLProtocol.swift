import Foundation

/// A `URLProtocol` stub that lets tests intercept `URLSession` traffic without touching the
/// network, so services that make real HTTP calls can be exercised end to end — including
/// request-body capture — in unit tests.
///
/// Usage:
/// ```swift
/// let session = MockURLProtocol.makeSession()
/// MockURLProtocol.handler = { request in
///     (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
///      someJSONData)
/// }
/// let sut = SheetsDriveService(session: session)
/// ```
final class MockURLProtocol: URLProtocol {

    /// Set per test. Receives the outgoing request and returns the response to hand back.
    /// Throwing simulates a network error.
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    /// Every request that reached the protocol, in order, so tests can assert on method, path,
    /// and headers.
    private(set) static var requests: [URLRequest] = []

    /// Request bodies, keyed by the order the requests arrived in. Multipart bodies arrive via
    /// `httpBodyStream` when `URLSession.upload` is used, so both sources are drained.
    private(set) static var bodies: [Data] = []

    private static let lock = NSLock()

    // MARK: - Setup

    static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: config)
    }

    static func reset() {
        lock.lock()
        defer { lock.unlock() }
        handler = nil
        requests = []
        bodies = []
    }

    // MARK: - Convenience responders

    /// Responds to any request with `json`, status 200.
    static func respond(json: String, statusCode: Int = 200) {
        handler = { request in
            (HTTPURLResponse(url: request.url!, statusCode: statusCode,
                             httpVersion: nil, headerFields: nil)!,
             Data(json.utf8))
        }
    }

    /// Responds with raw bytes — for the content endpoints, whose bodies are ciphertext.
    static func respond(data: Data, statusCode: Int = 200) {
        handler = { request in
            (HTTPURLResponse(url: request.url!, statusCode: statusCode,
                             httpVersion: nil, headerFields: nil)!,
             data)
        }
    }

    /// Routes by path suffix, so a test covering a multi-request flow can answer each leg.
    /// The first matching suffix wins; an unmatched request fails with a 404 so the omission shows
    /// up as a test failure rather than a hang.
    static func route(_ routes: [(suffix: String, statusCode: Int, body: Data)]) {
        handler = { request in
            let path = request.url?.path ?? ""
            let query = request.url?.query.map { "?\($0)" } ?? ""
            let full = path + query
            for route in routes where full.hasSuffix(route.suffix) || full.contains(route.suffix) {
                return (HTTPURLResponse(url: request.url!, statusCode: route.statusCode,
                                        httpVersion: nil, headerFields: nil)!,
                        route.body)
            }
            return (HTTPURLResponse(url: request.url!, statusCode: 404,
                                    httpVersion: nil, headerFields: nil)!,
                    Data())
        }
    }

    // MARK: - Inspection

    static func request(matching predicate: (URLRequest) -> Bool) -> URLRequest? {
        lock.lock()
        defer { lock.unlock() }
        return requests.first(where: predicate)
    }

    static var requestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return requests.count
    }

    // MARK: - URLProtocol

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.requests.append(request)
        if let stream = request.httpBodyStream {
            Self.bodies.append(Self.drain(stream))
        } else if let body = request.httpBody {
            Self.bodies.append(body)
        } else {
            Self.bodies.append(Data())
        }
        let handler = Self.handler
        Self.lock.unlock()

        guard let handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    private static func drain(_ stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 4096
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: bufferSize)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}
