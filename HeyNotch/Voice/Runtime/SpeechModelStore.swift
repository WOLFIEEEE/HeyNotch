import CryptoKit
import Foundation

private final class SpeechDownloadProgress: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let progress: @Sendable (Int64) -> Void
    init(_ progress: @escaping @Sendable (Int64) -> Void) { self.progress = progress }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) { progress(totalBytesWritten) }
}

actor SpeechModelStore {
    static let shared = SpeechModelStore()
    nonisolated let models: [SpeechModelManifest]
    private let root: URL
    private let session: URLSession

    init(root: URL? = nil, manifests: [SpeechModelManifest]? = nil) {
        self.root = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HeyNotch/SpeechModels", isDirectory: true)
        if let manifests { models = manifests.filter(\.valid) }
        else if let url = Bundle.main.url(forResource: "SpeechModels", withExtension: "json"),
                let data = try? Data(contentsOf: url), let decoded = try? JSONDecoder().decode([SpeechModelManifest].self, from: data) {
            models = decoded.filter(\.valid)
        } else { models = [] }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 45
        config.timeoutIntervalForResource = 900
        config.urlCache = nil
        session = URLSession(configuration: config)
    }

    private func folder(_ model: SpeechModelManifest) -> URL {
        root.appendingPathComponent("\(model.id)-\(model.repositoryRevision.prefix(12))", isDirectory: true)
    }

    func installed(_ model: SpeechModelManifest) -> Bool {
        model.files.allSatisfy { FileManager.default.fileExists(atPath: folder(model).appendingPathComponent($0.path).path) }
    }

    func prepare(_ model: SpeechModelManifest, allowDownload: Bool,
                 progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        guard model.valid, models.contains(where: { $0.id == model.id }) else { throw VoiceError.modelIntegrity }
        let destination = folder(model)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let capacity = try destination.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage ?? 0
        if allowDownload && capacity < model.byteCount + 256 * 1024 * 1024 { throw VoiceError.insufficientDisk }
        var completed: Int64 = 0
        for file in model.files {
            try Task.checkCancellation()
            let path = destination.appendingPathComponent(file.path)
            if try verify(path, file) {
                completed += file.size
                progress(Double(completed) / Double(model.byteCount))
                continue
            }
            guard allowDownload else { throw VoiceError.notReady }
            try? FileManager.default.removeItem(at: path)
            let already = completed, total = model.byteCount
            let delegate = SpeechDownloadProgress { bytes in progress(min(1, Double(already + min(bytes, file.size)) / Double(total))) }
            let temporary: URL
            do {
                let (url, response) = try await session.download(from: file.url, delegate: delegate)
                guard let response = response as? HTTPURLResponse, response.statusCode == 200 else { throw VoiceError.modelDownload }
                temporary = url
            } catch is CancellationError { throw CancellationError() }
            catch let error as URLError where error.code == .cancelled { throw CancellationError() }
            catch { throw VoiceError.modelDownload }
            defer { try? FileManager.default.removeItem(at: temporary) }
            try Task.checkCancellation()
            guard try verify(temporary, file) else { throw VoiceError.modelIntegrity }
            try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: temporary, to: path)
            completed += file.size
            progress(Double(completed) / Double(model.byteCount))
        }
        return destination
    }

    func delete(_ model: SpeechModelManifest) throws {
        let url = folder(model)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }

    private func verify(_ url: URL, _ file: SpeechModelManifest.File) throws -> Bool {
        guard FileManager.default.fileExists(atPath: url.path),
              (try url.resourceValues(forKeys: [.fileSizeKey])).fileSize == Int(file.size) else { return false }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var digest = SHA256()
        while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
            try Task.checkCancellation()
            digest.update(data: chunk)
        }
        return digest.finalize().map { String(format: "%02x", $0) }.joined() == file.sha256
    }
}
