import Foundation
import JavaScriptCore

/// The JS→Swift seam. Answers are JSON, so nothing non-`Sendable` crosses back to the JS queue.
@MainActor
protocol ExtensionHostAPI: AnyObject, Sendable {
    func perform(api: String, method: String, arguments: [RenderValue]) async throws -> String
    /// The context is gone; release anything opened on its behalf.
    func sessionEnded()
}

/// Where a running command's UI or failure lands. Every callback arrives on the main actor.
@MainActor
protocol ExtensionRuntimeDelegate: AnyObject {
    func runtime(_ runtime: ExtensionRuntime, session: String, didRender tree: RenderTree)
    func runtime(_ runtime: ExtensionRuntime, session: String, didFail message: String)
    func runtime(_ runtime: ExtensionRuntime, session: String, navigationDepth: Int)
    func runtime(_ runtime: ExtensionRuntime, session: String, didFinish: Void)
    func runtime(_ runtime: ExtensionRuntime, log level: String, message: String)
}

/// The one `JSContext` a command runs in; every touch is on `queue`, only values cross.
final class ExtensionRuntime: @unchecked Sendable {
    private let queue: DispatchQueue
    private var context: JSContext?
    private var timers: [String: DispatchSourceTimer] = [:]
    private var hostTasks: [String: Task<Void, Never>] = [:]
    private var generation = UUID()
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []
    private let nodeShims = ExtensionNodeShims()
    /// Progressive fetches in flight; chunks are pushed into the context as they arrive.
    private let streams = ExtensionFetchStreamRegistry()

    /// Set once at startup; read on the JS queue, so it is written before the runtime ever boots.
    private nonisolated(unsafe) weak var delegate: ExtensionRuntimeDelegate?
    private let hostAPI: ExtensionHostAPI
    private let runtimeOverride: URL?

    /// `runtimeURL` overrides the bundled runtime; only the harness passes it.
    init(hostAPI: ExtensionHostAPI, runtimeURL: URL? = nil, priority: DispatchQoS = .userInitiated) {
        queue = DispatchQueue(
            label: "com.tinycast.extensions.js", qos: priority, autoreleaseFrequency: .workItem)
        self.hostAPI = hostAPI
        self.runtimeOverride = runtimeURL
    }

    @MainActor
    func setDelegate(_ delegate: ExtensionRuntimeDelegate) {
        self.delegate = delegate
    }

    // MARK: - Lifecycle

    enum RuntimeError: LocalizedError {
        case runtimeResourceMissing
        case bootFailed(String)

        var errorDescription: String? {
            switch self {
            case .runtimeResourceMissing:
                return String(localized: "RaycastRuntime.generated.js is missing from the app bundle.")
            case .bootFailed(let message):
                return String(localized: "The extension runtime failed to start: \(message)")
            }
        }
    }

    /// Idempotent, so any command can lazily ensure the engine is up.
    func boot(config: ExtensionBootConfig) async throws {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    try self.bootOnQueue(config: config)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func bootOnQueue(config: ExtensionBootConfig) throws {
        guard context == nil else { return }
        guard
            let url = runtimeOverride
                ?? Bundle.main.url(forResource: "RaycastRuntime.generated", withExtension: "js"),
            let source = try? String(contentsOf: url, encoding: .utf8)
        else { throw RuntimeError.runtimeResourceMissing }

        guard let context = JSContext() else { throw RuntimeError.bootFailed("no JSContext") }

        var thrown: String?
        context.exceptionHandler = { _, exception in
            thrown = ExtensionRuntime.describe(exception)
        }
        installHost(in: context)
        context.evaluateScript(source, withSourceURL: url)
        if let thrown { throw RuntimeError.bootFailed(thrown) }
        // Stored only once it is known good: a half-built one would make every later boot a no-op.
        self.context = context

        // From here on an exception is a bug in a command: report it and keep going.
        context.exceptionHandler = { [weak self] _, exception in
            self?.report(level: "error", message: ExtensionRuntime.describe(exception))
        }

        let payload = config.jsonString()
        _ = context.objectForKeyedSubscript("__tinycast")?
            .invokeMethod("boot", withArguments: [payload])
    }

    /// Load and mount one command. `code` is its prebuilt CommonJS bundle.
    func start(
        session: String, code: String, file: URL, mode: ExtensionCommandMode,
        context launchContext: ExtensionLaunchContext
    ) async {
        let payload = launchContext.jsonString()
        await onQueue { context in
            let compiled = context.objectForKeyedSubscript("__tinycast")
            _ = compiled?.invokeMethod(
                "start",
                withArguments: [
                    session, code, file.path, file.deletingLastPathComponent().path,
                    mode.rawValue, payload
                ])
        }
    }

    /// Pre-encoded: `[Any]` isn't Sendable, so only the JSON string crosses onto the queue.
    func dispatch(session: String, handler: String, payload: String, completesSession: Bool = false) async {
        await onQueue { context in
            _ = context.objectForKeyedSubscript("__tinycast")?
                .invokeMethod("dispatch", withArguments: [session, handler, payload, completesSession])
        }
    }

    /// Escape or the back chevron inside a pushed screen; true when one was popped.
    func popNavigation(session: String) async -> Bool {
        await withCheckedContinuation { continuation in
            queue.async {
                guard let context = self.context else { return continuation.resume(returning: false) }
                let result = context.objectForKeyedSubscript("__tinycast")?
                    .invokeMethod("popNavigation", withArguments: [session])
                continuation.resume(returning: result?.toString() == "1")
            }
        }
    }

    func runToastAction(token: String) async {
        await onQueue { context in
            _ = context.objectForKeyedSubscript("__tinycast")?
                .invokeMethod("runToastAction", withArguments: [token])
        }
    }

    func stop(session: String) async {
        await onQueue { context in
            _ = context.objectForKeyedSubscript("__tinycast")?
                .invokeMethod("stop", withArguments: [session])
        }
        queue.async { self.nodeShims.closeFiles() }
    }

    private func onQueue(_ body: @escaping @Sendable (JSContext) -> Void) async {
        await withCheckedContinuation { continuation in
            queue.async {
                if let context = self.context { body(context) }
                continuation.resume()
            }
        }
    }

    // MARK: - Host object

    /// Installs `__tinycastHost` (the JS→Swift seam) and `__tinycastCompile`.
    private func installHost(in context: JSContext) {
        let host = JSValue(newObjectIn: context)

        let log: @convention(block) (String, String) -> Void = { [weak self] level, message in
            self?.report(level: level, message: message)
        }
        let render: @convention(block) (String, String) -> Void = { [weak self] session, json in
            self?.deliverRender(session: session, json: json)
        }
        let failed: @convention(block) (String, String) -> Void = { [weak self] session, message in
            guard let self else { return }
            let delegate = self.delegate
            Task { @MainActor in delegate?.runtime(self, session: session, didFail: message) }
        }
        let navigation: @convention(block) (String, String) -> Void = { [weak self] session, depth in
            guard let self else { return }
            let delegate = self.delegate
            let value = Int(depth) ?? 1
            Task { @MainActor in delegate?.runtime(self, session: session, navigationDepth: value) }
        }
        let finished: @convention(block) (String) -> Void = { [weak self] session in
            guard let self else { return }
            let delegate = self.delegate
            Task { @MainActor in delegate?.runtime(self, session: session, didFinish: ()) }
        }
        let fieldCommand: @convention(block) (String, String) -> Void = { _, _ in
            // Field focus requests have no native target yet; the palette focuses the first field.
        }
        let invoke: @convention(block) (String, String, String, String) -> Void = {
            [weak self] callId, api, method, argsJSON in
            self?.invokeAsync(callId: callId, api: api, method: method, argsJSON: argsJSON)
        }
        let invokeSync: @convention(block) (String, String, String) -> String = {
            [weak self] api, method, argsJSON in
            guard let self else { return #"{"ok":false,"error":"runtime gone"}"# }
            return self.nodeShims.perform(api: api, method: method, argsJSON: argsJSON)
        }
        let startTimer: @convention(block) (String, Double, Bool) -> Void = {
            [weak self] id, milliseconds, repeats in
            self?.startTimer(id: id, milliseconds: milliseconds, repeats: repeats)
        }
        let clearTimer: @convention(block) (String) -> Void = { [weak self] id in
            self?.clearTimer(id: id)
        }

        host?.setObject(log, forKeyedSubscript: "log" as NSString)
        host?.setObject(render, forKeyedSubscript: "render" as NSString)
        host?.setObject(failed, forKeyedSubscript: "failed" as NSString)
        host?.setObject(navigation, forKeyedSubscript: "navigationDepthChanged" as NSString)
        host?.setObject(finished, forKeyedSubscript: "finished" as NSString)
        host?.setObject(fieldCommand, forKeyedSubscript: "fieldCommand" as NSString)
        host?.setObject(invoke, forKeyedSubscript: "invoke" as NSString)
        host?.setObject(invokeSync, forKeyedSubscript: "invokeSync" as NSString)
        host?.setObject(startTimer, forKeyedSubscript: "startTimer" as NSString)
        host?.setObject(clearTimer, forKeyedSubscript: "clearTimer" as NSString)
        context.setObject(host, forKeyedSubscript: "__tinycastHost" as NSString)

        // Global scope is the point: the extension body must not see the runtime's own locals.
        let compile: @convention(block) (String, String) -> JSValue? = { [weak self] code, filename in
            guard let context = self?.context else { return nil }
            let wrapped = "(function (exports, require, module, __filename, __dirname) {\n\(code)\n})"
            return context.evaluateScript(wrapped, withSourceURL: URL(fileURLWithPath: filename))
        }
        context.setObject(compile, forKeyedSubscript: "__tinycastCompile" as NSString)
    }

    // MARK: - Host call plumbing

    private func invokeAsync(callId: String, api: String, method: String, argsJSON: String) {
        let generation = self.generation
        // A streaming fetch answers twice — once for the head, then once per chunk — so it never
        // reaches `hostAPI.perform`, which answers exactly once.
        if api == "fetch", method == "begin" {
            beginFetchStream(callId: callId, generation: generation, argsJSON: argsJSON)
            return
        }
        if api == "fetch", method == "cancel" {
            let cancelled = RenderValue.arguments(from: argsJSON)
            if let id = cancelled.first?.stringValue { streams.cancel(id) }
            settleQuietly(callId: callId, generation: generation, payload: "null")
            return
        }

        // Decode to `RenderValue` here so only `Sendable` values reach the main actor.
        let arguments = RenderValue.arguments(from: argsJSON)
        let hostAPI = self.hostAPI
        hostTasks[callId] = Task { @MainActor [weak self] in
            guard !Task.isCancelled else { return }
            do {
                let json = try await hostAPI.perform(
                    api: api, method: method, arguments: arguments)
                await self?.settle(callId: callId, generation: generation, ok: true, payload: json)
            } catch {
                await self?.settle(
                    callId: callId, generation: generation, ok: false,
                    payload: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            }
        }
    }

    private func settle(callId: String, generation: UUID, ok: Bool, payload: String) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async {
                defer { continuation.resume() }
                guard generation == self.generation else { return }
                self.hostTasks[callId] = nil
                _ = self.context?.objectForKeyedSubscript("__tinycast")?
                    .invokeMethod("settle", withArguments: [callId, ok, payload])
                if self.isIdle { self.resumeIdleWaiters() }
            }
        }
    }

    /// Starts a progressive fetch, then settles `callId` with the response head. Body chunks reach
    /// the context through `pushFetchChunk` until the stream closes.
    ///
    /// A spec this path cannot carry (a malformed URL, a Unix socket) answers `null` before touching
    /// the network, which is the one case the JS side retries over the buffered request. A failure
    /// once the request is on the wire is *not* retried: the server may already have run it.
    private func beginFetchStream(callId: String, generation: UUID, argsJSON: String) {
        let arguments = RenderValue.arguments(from: argsJSON)
        let spec = arguments.first
        guard let (request, socketPath) = try? ExtensionFetcher.makeRequest(spec), socketPath == nil
        else {
            settleQuietly(callId: callId, generation: generation, payload: "null")
            return
        }
        // Tracked like any other host call, so `drainHostCalls` waits for the head. `settle` clears
        // the entry from this queue, which is the queue this method already runs on.
        hostTasks[callId] = Task { [weak self] in
            // Shutdown cancels host tasks; a stream that has not started yet must not open one.
            guard let self, !Task.isCancelled else { return }
            var opened: String?
            do {
                let id = UUID().uuidString
                let stream = ExtensionFetchStream(
                    id: id,
                    request: request,
                    onChunk: { [weak self] data in
                        self?.pushFetchChunk(
                            id: id, generation: generation, data: data, done: false, message: nil)
                    },
                    onFinish: { [weak self] message in
                        self?.pushFetchChunk(
                            id: id, generation: generation, data: nil, done: true, message: message)
                    })
                streams.insert(stream)
                opened = id
                let head = try await stream.start()
                let json =
                    (try? JSONSerialization.data(withJSONObject: head))
                    .flatMap { String(data: $0, encoding: .utf8) } ?? "null"
                await self.settle(callId: callId, generation: generation, ok: true, payload: json)
            } catch {
                // A stream that never produced headers must not stay registered, and the caller gets
                // the failure rather than a second request.
                if let opened { self.streams.remove(opened) }
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                await self.settle(
                    callId: callId, generation: generation, ok: false, payload: message)
            }
        }
    }

    /// One chunk, or the close, on the JS queue that owns the context.
    private func pushFetchChunk(
        id: String, generation: UUID, data: Data?, done: Bool, message: String?
    ) {
        queue.async {
            // A stream outlives the session that opened it only until `cancelAll`; never feed its
            // tail into the next session's context.
            guard generation == self.generation else { return }
            let base64 = data?.base64EncodedString() ?? ""
            _ = self.context?.objectForKeyedSubscript("__tinycast")?
                .invokeMethod("fetchChunk", withArguments: [id, base64, done, message ?? ""])
            if done {
                self.streams.remove(id)
                if self.isIdle { self.resumeIdleWaiters() }
            }
        }
    }

    /// A host call with nothing to hand back (the JS side fires these and forgets them).
    private func settleQuietly(callId: String, generation: UUID, payload: String) {
        queue.async {
            // Call ids restart with each context, so a reply from an old one would land on a
            // different caller's promise.
            guard generation == self.generation else { return }
            self.hostTasks[callId] = nil
            _ = self.context?.objectForKeyedSubscript("__tinycast")?
                .invokeMethod("settle", withArguments: [callId, true, payload])
            if self.isIdle { self.resumeIdleWaiters() }
        }
    }

    /// Nothing is outstanding: no host call is pending, and no progressive fetch is still filling.
    /// A stream holds the context the way a buffered fetch used to, so a menu session cannot be torn
    /// down while an extension is still reading its body.
    private var isIdle: Bool { hostTasks.isEmpty && streams.isEmpty }

    func drainHostCalls() async {
        await withCheckedContinuation { continuation in
            queue.async {
                if self.isIdle {
                    continuation.resume()
                } else {
                    self.idleWaiters.append(continuation)
                }
            }
        }
    }

    private func resumeIdleWaiters() {
        let waiters = idleWaiters
        idleWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    private func deliverRender(session: String, json: String) {
        guard let delegate else { return }
        // Parsing a large list is the expensive part, and it belongs off the main actor.
        guard let tree = RenderTree(json: json) else {
            report(level: "error", message: "Could not decode the render tree for \(session).")
            return
        }
        Task { @MainActor in delegate.runtime(self, session: session, didRender: tree) }
    }

    private func report(level: String, message: String) {
        guard let delegate else { return }
        Task { @MainActor in delegate.runtime(self, log: level, message: message) }
    }

    // MARK: - Timers

    private func startTimer(id: String, milliseconds: Double, repeats: Bool) {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        let interval = max(milliseconds, 0) / 1000
        if repeats {
            timer.schedule(deadline: .now() + interval, repeating: max(interval, 0.001))
        } else {
            timer.schedule(deadline: .now() + interval)
        }
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            if !repeats { self.timers[id] = nil }
            _ = self.context?.objectForKeyedSubscript("__tinycast")?
                .invokeMethod("fireTimer", withArguments: [id])
        }
        timers[id]?.cancel()
        timers[id] = timer
        timer.resume()
    }

    private func clearTimer(id: String) {
        timers[id]?.cancel()
        timers[id] = nil
    }

    /// Timers are global and React's scheduler rides them, so a context is never reused.
    func shutdown() {
        let hostAPI = self.hostAPI
        Task { @MainActor in hostAPI.sessionEnded() }
        queue.async {
            self.streams.cancelAll()
            for timer in self.timers.values { timer.cancel() }
            self.timers.removeAll()
            for task in self.hostTasks.values { task.cancel() }
            self.hostTasks.removeAll()
            self.resumeIdleWaiters()
            self.generation = UUID()
            self.context = nil
            self.nodeShims.closeFiles()
        }
    }

    // MARK: - JSON helpers

    private static func describe(_ exception: JSValue?) -> String {
        guard let exception else { return "unknown JavaScript error" }
        let stack = exception.objectForKeyedSubscript("stack")?.toString()
        let message = exception.toString() ?? "JavaScript error"
        if let stack, !stack.isEmpty, stack != "undefined" { return "\(message)\n\(stack)" }
        return message
    }

    static func jsonArray(from json: String) -> [Any] {
        guard let data = json.data(using: .utf8),
            let array = try? JSONSerialization.jsonObject(with: data) as? [Any]
        else { return [] }
        return array
    }

    /// Fragment-tolerant encoding: host results are frequently bare strings, numbers or nil.
    static func jsonString(from value: Any?) -> String {
        guard let value, !(value is NSNull) else { return "" }
        guard
            let data = try? JSONSerialization.data(
                withJSONObject: value, options: [.fragmentsAllowed])
        else { return "" }
        return String(decoding: data, as: UTF8.self)
    }
}
