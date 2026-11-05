import Darwin
import Foundation
import XCTest

final class MediaStreamProcessTests: XCTestCase {
    private struct Message: Decodable { let text: String }

    private func stream(ignoresTermination: Bool = false, ready: XCTestExpectation) throws -> MediaStreamProcess {
        let script = (ignoresTermination ? "$SIG{TERM} = 'IGNORE'; " : "")
            + "$| = 1; print qq({\"text\":\"ready\"}\\n); sleep 60;"
        return try MediaStreamProcess(
            executableURL: URL(fileURLWithPath: "/usr/bin/perl"),
            arguments: ["-e", script], decoding: Message.self
        ) { message in
            XCTAssertEqual(message.text, "ready")
            ready.fulfill()
        }
    }

    private func assertChildGone(_ pid: Int32, file: StaticString = #filePath, line: UInt = #line) {
        errno = 0
        XCTAssertEqual(Darwin.kill(pid, 0), -1, "Owned child must be reaped", file: file, line: line)
        XCTAssertEqual(errno, ESRCH, file: file, line: line)
    }

    func testStopTerminatesIdleChildAndIsIdempotent() async throws {
        let ready = expectation(description: "Synthetic JSON delivered")
        let process = try stream(ready: ready)
        defer { process.stop() }
        await fulfillment(of: [ready], timeout: 3)
        let pid = process.processIdentifier
        XCTAssertTrue(process.isRunning)
        process.stop()
        process.stop()
        XCTAssertFalse(process.isRunning)
        assertChildGone(pid)
    }

    func testReleasingOwnerTerminatesChildWithoutWaitingForAnotherLine() async throws {
        let ready = expectation(description: "Synthetic JSON delivered")
        var process: MediaStreamProcess? = try stream(ready: ready)
        defer { process?.stop() }
        weak var owner = process
        await fulfillment(of: [ready], timeout: 3)
        let pid = try XCTUnwrap(process).processIdentifier
        process = nil
        XCTAssertNil(owner, "The stream task must not retain its owner")
        assertChildGone(pid)
    }

    func testStopImmediatelyAfterLaunchCannotLeaveLateChild() throws {
        for _ in 0..<5 {
            let process = try MediaStreamProcess(
                executableURL: URL(fileURLWithPath: "/bin/sleep"),
                arguments: ["60"], decoding: Message.self, onLine: { _ in XCTFail("No output expected") }
            )
            let pid = process.processIdentifier
            process.stop()
            assertChildGone(pid)
        }
    }

    func testUnresponsiveChildHasBoundedShutdown() async throws {
        let ready = expectation(description: "Child installed SIGTERM ignore")
        let process = try stream(ignoresTermination: true, ready: ready)
        defer { process.stop() }
        await fulfillment(of: [ready], timeout: 3)
        let pid = process.processIdentifier
        let start = ProcessInfo.processInfo.systemUptime
        process.stop()
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 1.5)
        assertChildGone(pid)
    }

    func testCancellationCompletesAnIdlePipeRead() async throws {
        let pipe = Pipe()
        let reader = JSONLinesPipeHandler(pipe: pipe)
        let firstLine = expectation(description: "First line received")
        let finished = expectation(description: "Cancelled idle reader returns")
        let task = Task {
            await reader.readJSONLines(as: Message.self) { _ in firstLine.fulfill() }
            finished.fulfill()
        }
        try pipe.fileHandleForWriting.write(contentsOf: Data("{\"text\":\"ready\"}\n".utf8))
        await fulfillment(of: [firstLine], timeout: 3)
        try await Task.sleep(for: .milliseconds(20))
        task.cancel()
        await fulfillment(of: [finished], timeout: 3)
        await reader.close()
    }

    func testRepeatedCloseResumesPendingReadExactlyOnce() async throws {
        let pipe = Pipe()
        let reader = JSONLinesPipeHandler(pipe: pipe)
        let finished = expectation(description: "Closed reader returns once")
        let task = Task {
            await reader.readJSONLines(as: Message.self) { _ in XCTFail("No output expected") }
            finished.fulfill()
        }
        try await Task.sleep(for: .milliseconds(20))
        async let first: Void = reader.close()
        async let second: Void = reader.close()
        task.cancel()
        _ = await (first, second)
        await fulfillment(of: [finished], timeout: 3)
    }

    func testSplitUnicodeLineAndNaturalEOFComplete() async throws {
        let pipe = Pipe()
        let reader = JSONLinesPipeHandler(pipe: pipe)
        let line = expectation(description: "Unicode decoded across chunks")
        let finished = expectation(description: "EOF finishes reader")
        let task = Task {
            await reader.readJSONLines(as: Message.self) { message in
                XCTAssertEqual(message.text, "hello 👋 café")
                line.fulfill()
            }
            finished.fulfill()
        }
        defer { task.cancel() }
        let data = Data("{\"text\":\"hello 👋 café\"}\n".utf8)
        let split = try XCTUnwrap(data.firstIndex(of: 0xF0)) + 2
        try pipe.fileHandleForWriting.write(contentsOf: data.prefix(split))
        try await Task.sleep(for: .milliseconds(20))
        try pipe.fileHandleForWriting.write(contentsOf: data.suffix(from: split))
        try pipe.fileHandleForWriting.close()
        await fulfillment(of: [line, finished], timeout: 3)
    }

    func testMissingExecutableFailsWithoutStartingChild() {
        XCTAssertThrowsError(try MediaStreamProcess(
            executableURL: URL(fileURLWithPath: "/nonexistent/HeyNotch-test-" + UUID().uuidString),
            arguments: [], decoding: Message.self, onLine: { _ in XCTFail("No output expected") }
        ))
    }

    func testProbeStopTerminatesItsOwnRunningChild() throws {
        let probe = MediaProbeProcess()
        let child = try probe.start(executableURL: URL(fileURLWithPath: "/bin/sleep"), arguments: ["60"])
        defer { probe.stop() }
        XCTAssertTrue(child.isRunning)
        probe.stop()
        probe.stop()
        assertChildGone(child.processIdentifier)
    }

    func testProbeCannotLaunchAfterStop() {
        let probe = MediaProbeProcess()
        probe.stop()
        XCTAssertThrowsError(try probe.start(executableURL: URL(fileURLWithPath: "/bin/sleep"), arguments: ["60"])) {
            XCTAssertTrue($0 is CancellationError)
        }
    }

    func testProbeConcurrentLaunchAndStopCannotOrphanChild() async {
        for _ in 0..<10 {
            let probe = MediaProbeProcess()
            let launch = Task.detached {
                try? probe.start(executableURL: URL(fileURLWithPath: "/bin/sleep"), arguments: ["60"])
            }
            probe.stop()
            if let child = await launch.value {
                assertChildGone(child.processIdentifier)
            }
        }
    }

    func testConcurrentProbeStopsBothWaitForOwnedChild() async throws {
        for _ in 0..<5 {
            let probe = MediaProbeProcess()
            let child = try probe.start(executableURL: URL(fileURLWithPath: "/bin/sleep"), arguments: ["60"])
            let first = Task.detached { probe.stop(); return child.isRunning }
            let second = Task.detached { probe.stop(); return child.isRunning }
            let firstSawRunningChild = await first.value
            let secondSawRunningChild = await second.value
            XCTAssertFalse(firstSawRunningChild)
            XCTAssertFalse(secondSawRunningChild)
            assertChildGone(child.processIdentifier)
        }
    }
}
