import CryptoKit
import Foundation
import XCTest

final class SpeechModelStoreTests: XCTestCase {
    private let revision = "0123456789abcdef"

    private func fixture(_ test: (URL, SpeechModelManifest, [Data]) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("HeyNotchTests.speech.\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let data = [Data("verified cached model file".utf8), Data("small missing model file".utf8)]
        let files = data.enumerated().map { index, bytes in
            SpeechModelManifest.File(path: "part-\(index).bin", url: URL(string: "https://huggingface.co/fixture/part-\(index)")!,
                                     sha256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(), size: Int64(bytes.count))
        }
        let model = SpeechModelManifest(id: "fixture", name: "Fixture", repositoryRevision: revision,
                                        tokenizerRevision: revision, files: files)
        try FileManager.default.createDirectory(at: folder(root), withIntermediateDirectories: true)
        try await test(root, model, data)
    }

    private func folder(_ root: URL) -> URL { root.appendingPathComponent("fixture-0123456789ab", isDirectory: true) }
    private func install(_ bytes: Data, index: Int, root: URL) throws {
        try bytes.write(to: folder(root).appendingPathComponent("part-\(index).bin"))
    }

    func testCompleteModelPreparesWithoutCapacityQueryOrDownload() async throws {
        try await fixture { root, model, data in
            for (index, bytes) in data.enumerated() { try install(bytes, index: index, root: root) }
            let store = SpeechModelStore(root: root, manifests: [model], availableCapacity: { _ in
                XCTFail("Already verified files need no download-space allocation")
                return 0
            }, download: { _, _ in XCTFail("A complete model must not download"); throw VoiceError.modelDownload })
            let result = try await store.prepare(model, allowDownload: true, progress: { _ in })
            XCTAssertEqual(result, folder(root))
        }
    }

    func testDownloadBudgetIncludesOnlyMissingFilesPlusHeadroom() async throws {
        try await fixture { root, model, data in
            try install(data[0], index: 0, root: root)
            let capacity = model.files[1].size + SpeechModelStore.downloadHeadroomBytes
            XCTAssertLessThan(capacity, model.byteCount + SpeechModelStore.downloadHeadroomBytes)
            let downloads = FixtureSpeechDownloads(bytes: [model.files[1].url: data[1]])
            let store = SpeechModelStore(root: root, manifests: [model], availableCapacity: { _ in capacity },
                                         download: { try await downloads.download($0, progress: $1) })
            _ = try await store.prepare(model, allowDownload: true, progress: { _ in })
            let requested = await downloads.requested
            XCTAssertEqual(requested, [model.files[1].url])
            for (index, bytes) in data.enumerated() {
                XCTAssertEqual(try Data(contentsOf: folder(root).appendingPathComponent("part-\(index).bin")), bytes)
            }
        }
    }

    func testInsufficientMissingFileBudgetKeepsVerifiedFilesAndDoesNotDownload() async throws {
        try await fixture { root, model, data in
            try install(data[0], index: 0, root: root)
            let capacity = model.files[1].size + SpeechModelStore.downloadHeadroomBytes - 1
            let store = SpeechModelStore(root: root, manifests: [model], availableCapacity: { _ in capacity },
                                         download: { _, _ in XCTFail("Capacity must be checked before download"); throw VoiceError.modelDownload })
            do {
                _ = try await store.prepare(model, allowDownload: true, progress: { _ in })
                XCTFail("The real headroom must remain available")
            } catch VoiceError.insufficientDisk {}
            XCTAssertEqual(try Data(contentsOf: folder(root).appendingPathComponent("part-0.bin")), data[0])
        }
    }

    func testCorruptExistingFileCountsAsMissingAndIsReplaced() async throws {
        try await fixture { root, model, data in
            try install(data[0], index: 0, root: root)
            try install(Data(repeating: 0, count: data[1].count), index: 1, root: root)
            let capacity = model.files[1].size + SpeechModelStore.downloadHeadroomBytes
            let downloads = FixtureSpeechDownloads(bytes: [model.files[1].url: data[1]])
            let store = SpeechModelStore(root: root, manifests: [model], availableCapacity: { _ in capacity },
                                         download: { try await downloads.download($0, progress: $1) })
            _ = try await store.prepare(model, allowDownload: true, progress: { _ in })
            XCTAssertEqual(try Data(contentsOf: folder(root).appendingPathComponent("part-1.bin")), data[1])
            let requested = await downloads.requested
            XCTAssertEqual(requested, [model.files[1].url])
        }
    }

    func testLocalOnlyMissingModelNeverQueriesCapacityOrDownloads() async throws {
        try await fixture { root, model, _ in
            let store = SpeechModelStore(root: root, manifests: [model], availableCapacity: { _ in XCTFail("No download requested"); return 0 },
                                         download: { _, _ in XCTFail("No download requested"); throw VoiceError.modelDownload })
            do {
                _ = try await store.prepare(model, allowDownload: false, progress: { _ in })
                XCTFail("Missing files must fail local-only preparation")
            } catch VoiceError.notReady {}
        }
    }

    func testDownloadedFileStillRequiresHashVerification() async throws {
        try await fixture { root, model, data in
            try install(data[0], index: 0, root: root)
            let downloads = FixtureSpeechDownloads(bytes: [model.files[1].url: Data(repeating: 0, count: data[1].count)])
            let store = SpeechModelStore(root: root, manifests: [model], availableCapacity: { _ in Int64.max },
                                         download: { try await downloads.download($0, progress: $1) })
            do {
                _ = try await store.prepare(model, allowDownload: true, progress: { _ in })
                XCTFail("A bad download must not be installed")
            } catch VoiceError.modelIntegrity {}
            XCTAssertFalse(FileManager.default.fileExists(atPath: folder(root).appendingPathComponent("part-1.bin").path))
            XCTAssertEqual(try Data(contentsOf: folder(root).appendingPathComponent("part-0.bin")), data[0])
            for temporary in await downloads.temporaryFiles {
                XCTAssertFalse(FileManager.default.fileExists(atPath: temporary.path))
            }
        }
    }
}

private actor FixtureSpeechDownloads {
    let bytes: [URL: Data]
    private(set) var requested: [URL] = []
    private(set) var temporaryFiles: [URL] = []
    init(bytes: [URL: Data]) { self.bytes = bytes }
    func download(_ url: URL, progress: @Sendable (Int64) -> Void) throws -> URL {
        requested.append(url)
        guard let data = bytes[url] else { throw VoiceError.modelDownload }
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("HeyNotchTests.download.\(UUID())")
        try data.write(to: temporary)
        temporaryFiles.append(temporary)
        progress(Int64(data.count))
        return temporary
    }
}
