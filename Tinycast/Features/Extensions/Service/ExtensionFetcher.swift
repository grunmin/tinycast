import Foundation
import Synchronization

/// Bodies cross the bridge base64-encoded, so binary responses survive.
final class ExtensionFetcher: Sendable {
    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: configuration)
    }

    deinit { session.invalidateAndCancel() }

    enum FetchError: LocalizedError {
        case badURL(String)
        case socketUnavailable(String)

        var errorDescription: String? {
            switch self {
            case .badURL(let url): return "Invalid URL: \(url)"
            case .socketUnavailable(let path):
                return
                    "Could not connect to the local service. Start its app or check the socket path: \(path)"
            }
        }
    }

    /// The wire request a spec describes. The buffered and streaming paths share this, so both send
    /// exactly what an extension asked for.
    static func makeRequest(_ spec: RenderValue?) throws -> (URLRequest, socketPath: String?) {
        let fields = spec?.objectValue ?? [:]
        let urlString = fields["url"]?.stringValue ?? ""
        guard let url = URL(string: urlString), url.scheme != nil else {
            throw FetchError.badURL(urlString)
        }

        var request = URLRequest(url: url)
        request.httpMethod = fields["method"]?.stringValue ?? "GET"
        for (name, value) in fields["headers"]?.objectValue ?? [:] {
            guard let text = value.stringValue else { continue }
            request.setValue(text, forHTTPHeaderField: name)
        }
        if let base64 = fields["bodyBase64"]?.stringValue, let body = Data(base64Encoded: base64) {
            request.httpBody = body
        }
        let socketPath = fields["socketPath"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
        return (request, socketPath)
    }

    func request(_ spec: RenderValue?) async throws -> [String: Any] {
        let (request, socketPath) = try Self.makeRequest(spec)
        let urlString = request.url?.absoluteString ?? ""

        let data: Data
        let response: URLResponse
        if let socketPath {
            (data, response) = try await Self.socketResponse(for: request, socketPath: socketPath)
        } else {
            (data, response) = try await session.data(for: request)
        }
        let http = response as? HTTPURLResponse
        var headers: [String: String] = [:]
        for (key, value) in http?.allHeaderFields ?? [:] {
            guard let name = key as? String, let text = value as? String else { continue }
            headers[name.lowercased()] = text
        }
        let status = http?.statusCode ?? 200
        return [
            "status": status,
            "statusText": HTTPURLResponse.localizedString(forStatusCode: status),
            "headers": headers,
            "url": response.url?.absoluteString ?? urlString,
            "bodyBase64": data.base64EncodedString()
        ]
    }

    @concurrent
    private static func socketResponse(
        for request: URLRequest, socketPath: String
    ) async throws -> (Data, HTTPURLResponse) {
        try Task.checkCancellation()
        guard let url = request.url, ["http", "https"].contains(url.scheme) else {
            throw URLError(.unsupportedURL)
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let marker = "\nTinycastSocketResponse:"
        var arguments = [
            "--disable", "--silent", "--globoff", "--noproxy", "*", "--compressed",
            "--max-time", "60", "--unix-socket", socketPath,
            "--request", request.httpMethod ?? "GET",
            "--write-out", marker + "{\"info\":%{json},\"headers\":%{header_json}}"
        ]
        for (name, value) in request.allHTTPHeaderFields ?? [:] {
            arguments += ["--header", value.isEmpty ? "\(name);" : "\(name): \(value)"]
        }
        if let body = request.httpBody {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700])
            let file = directory.appendingPathComponent("body")
            try body.write(to: file)
            arguments += ["--data-binary", "@\(file.path)"]
            if request.value(forHTTPHeaderField: "Content-Type") == nil {
                arguments += ["--header", "Content-Type:"]
            }
        }
        if request.httpMethod == "HEAD" { arguments += ["--head"] }
        arguments += ["--url", url.absoluteString]
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let bytes = try await withTaskCancellationHandler {
            let exit = try process.runObservingExit()
            if Task.isCancelled, process.isRunning { process.terminate() }
            let bytes: Data = try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(
                        with: Result {
                            defer {
                                if process.isRunning { process.terminate() }
                                exit.wait()
                            }
                            let bytes = try output.fileHandleForReading.readToEnd() ?? Data()
                            exit.wait()
                            return bytes
                        })
                }
            }
            try Task.checkCancellation()
            guard process.terminationStatus == 0 else {
                if process.terminationStatus == 7 { throw FetchError.socketUnavailable(socketPath) }
                throw URLError(process.terminationStatus == 28 ? .timedOut : .cannotConnectToHost)
            }
            return bytes
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
        guard let boundary = bytes.range(of: Data(marker.utf8), options: .backwards),
            let metadata = try JSONSerialization.jsonObject(with: bytes.suffix(from: boundary.upperBound))
                as? [String: Any],
            let info = metadata["info"] as? [String: Any], let status = info["http_code"] as? Int,
            let rawHeaders = metadata["headers"] as? [String: [String]]
        else { throw URLError(.badServerResponse) }
        let headers = rawHeaders.mapValues { $0.joined(separator: ", ") }
        guard
            let response = HTTPURLResponse(
                url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)
        else { throw URLError(.badServerResponse) }
        return (request.httpMethod == "HEAD" ? Data() : bytes.prefix(upTo: boundary.lowerBound), response)
    }
}

/// `ExtensionNodeShims` launches a child on the JS queue; `wait` collects it off that queue.
enum ExtensionAsyncProcess {
    enum ProcessError: LocalizedError {
        case notStarted

        var errorDescription: String? { "No running child process with that pid." }
    }

    struct Child: Sendable {
        let task: Process
        let exit: ProcessExit
        let stdout: Pipe
        let stderr: Pipe

        /// A child filling the 64 KB pipe blocks before it can exit, so the drain comes first.
        func collect(timeout: Double?) -> [String: Any] {
            var watchdog: DispatchSourceTimer?
            if let timeout, timeout > 0 { watchdog = terminationWatchdog(after: timeout / 1000) }
            let outData = stdout.fileHandleForReading.readDataToEndOfFile()
            let errData = stderr.fileHandleForReading.readDataToEndOfFile()
            exit.wait()
            watchdog?.cancel()

            return [
                "stdout": outData.base64EncodedString(),
                "stderr": errData.base64EncodedString(),
                "status": Int(task.terminationStatus),
                "signal": task.terminationReason == .uncaughtSignal ? "SIGTERM" : NSNull()
            ]
        }

        /// Signals the pid rather than the `Process`, which a `@Sendable` timer handler cannot capture.
        fileprivate func terminationWatchdog(after seconds: Double) -> DispatchSourceTimer {
            let pid = task.processIdentifier
            let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
            timer.schedule(deadline: .now() + seconds)
            timer.setEventHandler { kill(pid, SIGTERM) }
            timer.resume()
            return timer
        }
    }

    /// Started by `enqueue` and not yet claimed by `wait`, keyed by pid.
    private static let uncollected = Mutex<[Int32: (child: Child, watchdog: DispatchSourceTimer?)]>([:])

    /// An app bundle inherits no login shell, so a bare `brew` would otherwise fail.
    static func resolveExecutable(_ command: String) -> URL? {
        let fileManager = FileManager.default
        if command.contains("/") {
            let expanded = (command as NSString).expandingTildeInPath
            return fileManager.isExecutableFile(atPath: expanded)
                ? URL(fileURLWithPath: expanded) : nil
        }
        let search =
            (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
            + [
                "/opt/homebrew/bin", "/opt/homebrew/sbin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin",
                "/sbin"
            ]
        for directory in search {
            let candidate = (directory as NSString).appendingPathComponent(command)
            if fileManager.isExecutableFile(atPath: candidate) {
                return URL(fileURLWithPath: candidate)
            }
        }
        return nil
    }

    static func enqueue(_ child: Child, timeout: Double?) {
        // Armed at launch: `wait` only starts once streaming output has ended.
        let watchdog = timeout.flatMap { $0 > 0 ? child.terminationWatchdog(after: $0 / 1000) : nil }
        uncollected.withLock { $0[child.task.processIdentifier] = (child, watchdog) }
    }

    /// Next chunk of fd 1 or 2, nil at EOF; `wait` then finds both pipes drained.
    static func read(_ arguments: [RenderValue]) async throws -> String? {
        guard let pid = arguments.first?.doubleValue.flatMap({ Int32(exactly: $0) }),
            let child = uncollected.withLock({ $0[pid]?.child })
        else { throw ProcessError.notStarted }
        let pipe = arguments[safe: 1]?.doubleValue == 2 ? child.stderr : child.stdout
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let data = pipe.fileHandleForReading.availableData
                continuation.resume(returning: data.isEmpty ? nil : data.base64EncodedString())
            }
        }
    }

    static func wait(_ pid: RenderValue?) async throws -> [String: Any] {
        guard let pid = pid?.doubleValue.flatMap({ Int32(exactly: $0) }),
            let entry = uncollected.withLock({ $0.removeValue(forKey: pid) })
        else { throw ProcessError.notStarted }

        let child = entry.child
        let result = await withCheckedContinuation { continuation in
            // The drain blocks until the child closes its output, which can be minutes away.
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: child.collect(timeout: nil))
            }
        }
        entry.watchdog?.cancel()
        return result
    }
}

/// One progressive HTTP response.
///
/// `start()` settles as soon as the headers are in, so the extension's `fetch` can hand back a
/// `Response` whose body is still filling; every body chunk then reaches `onChunk` as URLSession
/// delivers it, and `onFinish` closes the stream. This exists because the buffered path
/// (`URLSession.data(for:)`) hands the extension one finished `Data`, which a caller reading
/// `response.body` sees as a single chunk — no streaming render for an SSE reply.
final class ExtensionFetchStream: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    let id: String

    private let request: URLRequest
    private let onChunk: @Sendable (Data) -> Void
    private let onFinish: @Sendable (String?) -> Void

    /// URLSession calls back on its own queue; the head settles there, the JS side hops itself.
    private let lock = NSLock()
    private var continuation: CheckedContinuation<[String: Any], Error>?
    private var settled = false
    private var cancelled = false
    private var status = 200
    private var headers: [String: String] = [:]
    private var urlString = ""
    private var session: URLSession?
    private var task: URLSessionDataTask?

    init(
        id: String,
        request: URLRequest,
        onChunk: @escaping @Sendable (Data) -> Void,
        onFinish: @escaping @Sendable (String?) -> Void
    ) {
        self.id = id
        self.request = request
        self.onChunk = onChunk
        self.onFinish = onFinish
        super.init()
    }

    /// Returns the response head; the body keeps arriving afterwards.
    func start() async throws -> [String: Any] {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            self.continuation = continuation
            lock.unlock()

            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 60
            configuration.httpCookieStorage = nil
            configuration.urlCredentialStorage = nil
            configuration.urlCache = nil
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            let session = URLSession(
                configuration: configuration, delegate: self, delegateQueue: nil)
            let task = session.dataTask(with: request)
            // The registry holds this stream before the task exists, so a session can be torn down
            // in between: cancel what is already cancelled, then resume either way so the head
            // settles through the delegate path rather than hanging.
            lock.lock()
            self.session = session
            self.task = task
            let cancelledEarly = cancelled
            lock.unlock()
            if cancelledEarly { task.cancel() }
            task.resume()
        }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let task = self.task
        lock.unlock()
        task?.cancel()
    }

    // MARK: - URLSessionDataDelegate

    func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        let http = response as? HTTPURLResponse
        var collected: [String: String] = [:]
        for (key, value) in http?.allHeaderFields ?? [:] {
            guard let name = key as? String, let text = value as? String else { continue }
            collected[name.lowercased()] = text
        }

        lock.lock()
        let isFirst = !settled
        if isFirst {
            settled = true
            status = http?.statusCode ?? 200
            headers = collected
            urlString = response.url?.absoluteString ?? request.url?.absoluteString ?? ""
        }
        let pending = isFirst ? continuation : nil
        if isFirst { self.continuation = nil }
        let head = status
        let headHeaders = headers
        let headURL = urlString
        lock.unlock()

        if let pending {
            pending.resume(
                returning: [
                    "id": id,
                    "status": head,
                    "statusText": HTTPURLResponse.localizedString(forStatusCode: head),
                    "headers": headHeaders,
                    "url": headURL
                ])
        }
        completionHandler(.allow)
    }

    func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data
    ) {
        onChunk(data)
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?
    ) {
        lock.lock()
        let pending = settled ? nil : continuation
        if !settled { settled = true }
        self.continuation = nil
        lock.unlock()

        if let pending {
            // No headers ever arrived: fail the call, and let the JS side fall back to buffering.
            pending.resume(throwing: error ?? URLError(.badServerResponse))
        } else {
            onFinish(error?.localizedDescription)
        }
        session.finishTasksAndInvalidate()
    }
}

/// Streaming fetches in flight, keyed by the id the JS side holds. URLSession's queue and the JS
/// queue both reach it, so it carries its own lock.
final class ExtensionFetchStreamRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var streams: [String: ExtensionFetchStream] = [:]

    func insert(_ stream: ExtensionFetchStream) {
        lock.lock()
        streams[stream.id] = stream
        lock.unlock()
    }

    func cancel(_ id: String) {
        lock.lock()
        let stream = streams.removeValue(forKey: id)
        lock.unlock()
        stream?.cancel()
    }

    func remove(_ id: String) {
        lock.lock()
        streams[id] = nil
        lock.unlock()
    }

    var isEmpty: Bool {
        lock.lock()
        defer { lock.unlock() }
        return streams.isEmpty
    }

    func cancelAll() {
        lock.lock()
        let all = Array(streams.values)
        streams.removeAll()
        lock.unlock()
        for stream in all { stream.cancel() }
    }
}
