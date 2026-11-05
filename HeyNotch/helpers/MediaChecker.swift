//
//  MediaChecker.swift
//  HeyNotch
//
//  Created by Alexander on 2025-07-26.
//

import Foundation

final class MediaChecker: Sendable {
    private let probe = MediaProbeProcess()

    func stop() { probe.stop() }

    enum MediaCheckerError: Error {
        case missingResources
        case processExecutionFailed
        case timeout
    }

    func checkDeprecationStatus() async throws -> Bool {
        // The bundled adapter was built for macOS 15. Keep the existing direct
        // Apple Music/Spotify choices available on macOS 14 instead of launching it.
        guard #available(macOS 15.0, *) else { return true }

        return try await withTaskCancellationHandler {
            try await Task.detached(priority: .userInitiated) { [probe] in
                guard let scriptURL = Bundle.main.url(forResource: "mediaremote-adapter", withExtension: "pl"),
                      let nowPlayingTestClientPath = Bundle.main.url(forResource: "MediaRemoteAdapterTestClient", withExtension: nil)?.path,
                      let frameworkPath = Bundle.main.privateFrameworksPath?.appending("/MediaRemoteAdapter.framework")
                else {
                    throw MediaCheckerError.missingResources
                }

                let process: Process
                do {
                    process = try probe.start(
                        executableURL: URL(fileURLWithPath: "/usr/bin/perl"),
                        arguments: [scriptURL.path, frameworkPath, nowPlayingTestClientPath, "test"]
                    )
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    throw MediaCheckerError.processExecutionFailed
                }
                defer { probe.finish(process) }

                // Timeout after 10 seconds
                let didExit: Bool = try await withThrowingTaskGroup(of: Bool.self) { group in
                    group.addTask {
                        process.waitUntilExit()
                        return true
                    }
                    group.addTask {
                        try await Task.sleep(for: .seconds(10))
                        probe.stop()
                        return false // Timed out
                    }
                    for try await exited in group {
                        if exited {
                            group.cancelAll()
                            return true
                        }
                    }
                    throw MediaCheckerError.timeout
                }

                if !didExit {
                    throw MediaCheckerError.timeout
                }

                let isDeprecated = process.terminationStatus == 1
                return isDeprecated
            }.value
        } onCancel: {
            probe.stop()
        }
    }
}
