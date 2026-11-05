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
    typealias Download = @Sendable (URL, @escaping @Sendable (Int64) -> Void) async throws -> URL
    static let shared = SpeechModelStore()
    // Keep room for filesystem bookkeeping and loading caches while adding
    // files. Already verified models do not need another download allocation.
    static let downloadHeadroomBytes: Int64 = 256 * 1024 * 1024
    nonisolated let models: [SpeechModelManifest]
    private let root: URL
    private let availableCapacity: @Sendable (URL) throws -> Int64
    private let download: Download

    init(root: URL? = nil, manifests: [SpeechModelManifest]? = nil,
         availableCapacity: @escaping @Sendable (URL) throws -> Int64 = { url in
             try url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
                 .volumeAvailableCapacityForImportantUsage ?? 0
         }, download: Download? = nil) {
        self.root = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HeyNotch/SpeechModels", isDirectory: true)
        self.availableCapacity = availableCapacity
        if let manifests { models = manifests.filter(\.valid) }
        else if let url = Bundle.main.url(forResource: "SpeechModels", withExtension: "json"),
                let data = try? Data(contentsOf: url), let decoded = try? JSONDecoder().decode([SpeechModelManifest].self, from: data) {
            models = decoded.filter(\.valid)
        } else { models = [] }
        if let download { self.download = download }
        else {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 45
            config.timeoutIntervalForResource = 900
            config.urlCache = nil
            let session = URLSession(configuration: config)
            self.download = { url, progress in
                let (temporary, response) = try await session.download(from: url, delegate: SpeechDownloadProgress(progress))
                guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
                    try? FileManager.default.removeItem(at: temporary)
                    throw VoiceError.modelDownload
                }
                return temporary
            }
        }
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
        var completed: Int64 = 0
        var missing: [SpeechModelManifest.File] = []
        for file in model.files {
            try Task.checkCancellation()
            let path = destination.appendingPathComponent(file.path)
            if try verify(path, file) {
                completed += file.size
                progress(Double(completed) / Double(model.byteCount))
            } else { missing.append(file) }
        }
        guard !missing.isEmpty else { return destination }
        guard allowDownload else { throw VoiceError.notReady }
        try Task.checkCancellation()
        let missingBytes = missing.reduce(Int64(0)) { $0 + $1.size }
        guard try availableCapacity(destination) >= missingBytes + Self.downloadHeadroomBytes else {
            throw VoiceError.insufficientDisk
        }
        for file in missing {
            try Task.checkCancellation()
            let path = destination.appendingPathComponent(file.path)
            try? FileManager.default.removeItem(at: path)
            let already = completed, total = model.byteCount
            let temporary: URL
            do {
                temporary = try await download(file.url) { bytes in
                    progress(min(1, Double(already + min(bytes, file.size)) / Double(total)))
                }
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
