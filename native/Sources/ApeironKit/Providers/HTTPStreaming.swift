import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Streams the body of an HTTP response line by line.
public protocol HTTPLineStreaming: Sendable {
    func lines(for request: URLRequest) -> AsyncThrowingStream<String, Error>
}

/// Delegate-based streaming that works with both Darwin Foundation and
/// swift-corelibs-foundation (which lacks `URLSession.bytes`).
public struct URLSessionLineStreamer: HTTPLineStreaming {
    public var timeout: TimeInterval

    public init(timeout: TimeInterval = 600) {
        self.timeout = timeout
    }

    public func lines(for request: URLRequest) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let delegate = LineStreamDelegate(continuation: continuation)
            let configuration = URLSessionConfiguration.default
            configuration.timeoutIntervalForRequest = timeout
            configuration.timeoutIntervalForResource = max(timeout, 3600)
            let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
            let task = session.dataTask(with: request)
            continuation.onTermination = { _ in
                task.cancel()
                session.invalidateAndCancel()
            }
            task.resume()
        }
    }
}

private final class LineStreamDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let continuation: AsyncThrowingStream<String, Error>.Continuation
    private let lock = NSLock()
    private var buffer = Data()
    private var errorBody = Data()
    private var status = 200
    private var retryAfter: TimeInterval?

    init(continuation: AsyncThrowingStream<String, Error>.Continuation) {
        self.continuation = continuation
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        if let http = response as? HTTPURLResponse {
            lock.lock()
            status = http.statusCode
            if let value = http.value(forHTTPHeaderField: "retry-after"), let seconds = TimeInterval(value) {
                retryAfter = seconds
            }
            lock.unlock()
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        defer { lock.unlock() }
        guard (200..<300).contains(status) else {
            errorBody.append(data)
            return
        }
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            var lineData = buffer[buffer.startIndex..<newline]
            if lineData.last == 0x0D { lineData = lineData.dropLast() }
            buffer.removeSubrange(buffer.startIndex...newline)
            continuation.yield(String(decoding: lineData, as: UTF8.self))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let status = self.status
        let remaining = buffer
        let body = errorBody
        let retryAfter = self.retryAfter
        lock.unlock()

        if let error {
            let nsError = error as NSError
            if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled {
                continuation.finish(throwing: CancellationError())
            } else {
                continuation.finish(throwing: ProviderError.transport(error.localizedDescription))
            }
        } else if !(200..<300).contains(status) {
            continuation.finish(throwing: ProviderError.http(
                status: status,
                body: String(decoding: body, as: UTF8.self),
                retryAfter: retryAfter
            ))
        } else {
            if !remaining.isEmpty {
                continuation.yield(String(decoding: remaining, as: UTF8.self))
            }
            continuation.finish()
        }
        session.finishTasksAndInvalidate()
    }
}

/// A server-sent event.
public struct SSEEvent: Equatable, Sendable {
    public var event: String?
    public var data: String
}

/// Incremental SSE parser: feed it lines, it emits events on blank lines.
public struct SSEParser: Sendable {
    private var event: String?
    private var dataLines: [String] = []

    public init() {}

    public mutating func feed(_ line: String) -> SSEEvent? {
        if line.isEmpty {
            return flush()
        }
        if line.hasPrefix(":") { return nil }
        let (field, value): (Substring, Substring)
        if let colon = line.firstIndex(of: ":") {
            field = line[line.startIndex..<colon]
            var rest = line[line.index(after: colon)...]
            if rest.first == " " { rest = rest.dropFirst() }
            value = rest
        } else {
            field = Substring(line)
            value = ""
        }
        switch field {
        case "event": event = String(value)
        case "data": dataLines.append(String(value))
        default: break
        }
        return nil
    }

    public mutating func flush() -> SSEEvent? {
        defer {
            event = nil
            dataLines = []
        }
        guard !dataLines.isEmpty else { return nil }
        return SSEEvent(event: event, data: dataLines.joined(separator: "\n"))
    }
}

public extension HTTPLineStreaming {
    /// Convenience: an SSE event stream over a line stream.
    func events(for request: URLRequest) -> AsyncThrowingStream<SSEEvent, Error> {
        let lines = self.lines(for: request)
        return AsyncThrowingStream { continuation in
            let task = Task {
                var parser = SSEParser()
                do {
                    for try await line in lines {
                        if let event = parser.feed(line) { continuation.yield(event) }
                    }
                    if let event = parser.flush() { continuation.yield(event) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
