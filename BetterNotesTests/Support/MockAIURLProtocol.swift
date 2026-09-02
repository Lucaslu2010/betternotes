import Foundation

/// Stubs the provider HTTP layer so AI code paths can be exercised without
/// a network or an API key. Shared by every test that needs a fake provider.
final class MockAIURLProtocol: URLProtocol {
    struct Stub {
        let statusCode: Int
        let data: Data
        let error: Error?
        let delay: TimeInterval

        init(statusCode: Int = 200, body: String = "", error: Error? = nil, delay: TimeInterval = 0) {
            self.statusCode = statusCode
            self.data = Data(body.utf8)
            self.error = error
            self.delay = delay
        }
    }

    private static let stateLock = NSLock()
    private static var stubs: [Stub] = []
    private static var requests: [URLRequest] = []
    private var delivery: DispatchWorkItem?

    static func install(_ newStubs: [Stub]) {
        stateLock.lock()
        stubs = newStubs
        requests = []
        stateLock.unlock()
    }

    static func recordedRequests() -> [URLRequest] {
        stateLock.lock()
        defer { stateLock.unlock() }
        return requests
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var recordedRequest = request
        if recordedRequest.httpBody == nil, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var body = Data()
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 4_096)
            defer { buffer.deallocate() }
            while stream.hasBytesAvailable {
                let count = stream.read(buffer, maxLength: 4_096)
                guard count > 0 else { break }
                body.append(buffer, count: count)
            }
            recordedRequest.httpBody = body
        }

        Self.stateLock.lock()
        Self.requests.append(recordedRequest)
        let stub = Self.stubs.isEmpty
            ? Stub(error: URLError(.badServerResponse))
            : Self.stubs.removeFirst()
        Self.stateLock.unlock()

        let work = DispatchWorkItem { [weak self] in
            guard let self, !Task.isCancelled else { return }
            if let error = stub.error {
                client?.urlProtocol(self, didFailWithError: error)
                return
            }
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: stub.statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: stub.data)
            client?.urlProtocolDidFinishLoading(self)
        }
        delivery = work
        if stub.delay > 0 {
            DispatchQueue.global().asyncAfter(deadline: .now() + stub.delay, execute: work)
        } else {
            work.perform()
        }
    }

    override func stopLoading() {
        delivery?.cancel()
        delivery = nil
    }
}
