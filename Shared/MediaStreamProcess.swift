import Darwin
import Foundation

/// Owns the lifetime of one streaming media adapter, including an idle pipe read.
/// Call stop before releasing the controller: application exit does not run ARC cleanup.
final class MediaStreamProcess {
    private let process: Process
    private let pipeHandler: JSONLinesPipeHandler
    private let exited = DispatchSemaphore(value: 0)
    private var streamTask: Task<Void, Never>?
    private var stopped = false

    var processIdentifier: Int32 { process.processIdentifier }
    var isRunning: Bool { process.isRunning }

    init<T: Decodable>(
        executableURL: URL,
        arguments: [String],
        decoding type: T.Type,
        onLine: @escaping (T) async -> Void
    ) throws {
        let pipe = Pipe()
        let handler = JSONLinesPipeHandler(pipe: pipe)
        pipeHandler = handler
        process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardOutput = pipe
        let exited = self.exited
        process.terminationHandler = { _ in exited.signal() }
        do {
            // There is no suspension between launch and ownership. A controller
            // cannot finish stopping and then launch a late adapter task.
            try process.run()
            // Only the child writes. Keeping the parent's copy open would
            // prevent EOF when the adapter exits on its own.
            try? pipe.fileHandleForWriting.close()
        } catch {
            Task { await handler.close() }
            throw error
        }
        streamTask = Task {
            await handler.readJSONLines(as: type, onLine: onLine)
        }
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        streamTask?.cancel()
        streamTask = nil
        let handler = pipeHandler
        Task { await handler.close() }
        MediaProcessShutdown.stop(process, exited: exited)
    }

    deinit { stop() }
}

/// Serializes launch against shutdown for the one-shot compatibility probe.
final class MediaProbeProcess: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var exited: DispatchSemaphore?
    private var stopped = false

    func start(executableURL: URL, arguments: [String]) throws -> Process {
        lock.lock()
        defer { lock.unlock() }
        guard !stopped, process == nil else { throw CancellationError() }
        let child = Process()
        let didExit = DispatchSemaphore(value: 0)
        child.executableURL = executableURL
        child.arguments = arguments
        child.terminationHandler = { _ in didExit.signal() }
        try child.run()
        process = child
        exited = didExit
        return child
    }

    func finish(_ child: Process) {
        lock.lock()
        defer { lock.unlock() }
        if process === child {
            process = nil
            exited = nil
        }
    }

    func stop() {
        lock.lock()
        defer { lock.unlock() }
        stopped = true
        let child = process
        let didExit = exited
        process = nil
        exited = nil
        // Concurrent cancellation and application exit must both wait for the
        // bounded shutdown, not mistake an in-progress stop for completion.
        if let child, let didExit {
            MediaProcessShutdown.stop(child, exited: didExit)
        }
    }

    deinit { stop() }
}

private enum MediaProcessShutdown {
    static func stop(_ process: Process, exited: DispatchSemaphore) {
        guard process.isRunning else { return }
        process.terminate()
        // Usually SIGTERM exits immediately. Bound shutdown if a helper stops
        // responding; never let a waitUntilExit block the app's main thread.
        if exited.wait(timeout: .now() + .milliseconds(250)) == .timedOut,
           process.isRunning {
            Darwin.kill(process.processIdentifier, SIGKILL)
            _ = exited.wait(timeout: .now() + .milliseconds(250))
        }
    }

}

actor JSONLinesPipeHandler {
    private let pipe: Pipe
    private let fileHandle: FileHandle
    private var buffer = Data()
    private var closed = false
    private var pendingRead: (id: UUID, continuation: CheckedContinuation<Data, Error>)?

    init(pipe: Pipe = Pipe()) {
        self.pipe = pipe
        fileHandle = pipe.fileHandleForReading
        let descriptor = fileHandle.fileDescriptor
        let flags = fcntl(descriptor, F_GETFL)
        _ = fcntl(descriptor, F_SETFL, flags | O_NONBLOCK)
    }

    func readJSONLines<T: Decodable>(as type: T.Type, onLine: @escaping (T) async -> Void) async {
        await withTaskCancellationHandler {
            do {
                while !Task.isCancelled && !closed {
                    let data = try await readData()
                    guard !data.isEmpty else { break }
                    // Keep bytes until the line is complete, including UTF-8
                    // characters split across pipe reads.
                    buffer.append(data)
                    while let newline = buffer.firstIndex(of: 0x0A) {
                        let line = buffer.prefix(upTo: newline)
                        buffer.removeSubrange(...newline)
                        guard !Task.isCancelled && !closed else { break }
                        if let object = try? JSONDecoder().decode(T.self, from: line) {
                            await onLine(object)
                        }
                    }
                }
            } catch {
                if !Task.isCancelled && !closed {
                    print("Error processing JSON stream: \(error)")
                }
            }
            close()
        } onCancel: {
            Task { await self.close() }
        }
    }

    private func readData() async throws -> Data {
        guard !closed && !Task.isCancelled else { return Data() }
        return try await withCheckedThrowingContinuation { continuation in
            let id = UUID()
            pendingRead = (id, continuation)
            installReadabilityHandler(for: id)
        }
    }

    private func installReadabilityHandler(for id: UUID) {
        fileHandle.readabilityHandler = { [weak self] handle in
            // One callback per pending read, even while the actor is busy.
            handle.readabilityHandler = nil
            Task { await self?.readAvailableData(for: id) }
        }
    }

    private func readAvailableData(for id: UUID) {
        guard !closed, let pending = pendingRead, pending.id == id else { return }
        var bytes = [UInt8](repeating: 0, count: 65_536)
        let count = Darwin.read(fileHandle.fileDescriptor, &bytes, bytes.count)
        if count < 0 && (errno == EAGAIN || errno == EINTR) {
            installReadabilityHandler(for: id)
            return
        }
        fileHandle.readabilityHandler = nil
        pendingRead = nil
        if count < 0 {
            pending.continuation.resume(throwing: POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO))
        } else {
            pending.continuation.resume(returning: Data(bytes.prefix(count)))
        }
    }

    func close() {
        guard !closed else { return }
        closed = true
        fileHandle.readabilityHandler = nil
        let pending = pendingRead
        pendingRead = nil
        pending?.continuation.resume(returning: Data())
        try? fileHandle.close()
        try? pipe.fileHandleForWriting.close()
        buffer.removeAll()
    }
}
