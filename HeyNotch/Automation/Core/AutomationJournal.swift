import Darwin
import Foundation

/// One engine owns this bounded journal. No operation keys are evicted or retried
/// automatically; a pending entry recovered after restart is an uncertain write.
actor AutomationJournal {
    struct Entry: Codable, Sendable {
        let clientID: String
        let operationID: UUID
        let fingerprint: String
        let internalID: UUID
        let listIDs: Set<String>
        var state: State
        var response: Data?
        enum State: String, Codable, Sendable { case pending, succeeded, failed, uncertain }
    }
    private struct Envelope: Codable { let version: Int; let entries: [String: Entry] }
    static let maximumEntries = 10_000
    static let maximumBytes = 64 * 1_024 * 1_024
    private let url: URL
    private var entries: [String: Entry] = [:]
    private var unavailable = false
    private var loaded = false

    init(url: URL) { self.url = url }

    private func load() {
        guard !loaded else { return }
        loaded = true
        do {
            guard FileManager.default.fileExists(atPath: url.path) else { return }
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true,
                  let size = values.fileSize, size <= Self.maximumBytes else { throw failure() }
            let envelope = try JSONDecoder().decode(Envelope.self, from: Data(contentsOf: url))
            guard envelope.version == 1, envelope.entries.count <= Self.maximumEntries else { throw failure() }
            for (key, entry) in envelope.entries {
                guard key == Self.key(clientID: entry.clientID, operationID: entry.operationID),
                      entry.fingerprint.count == 64,
                      entry.response.map({ $0.count <= AutomationJSON.maximumResponseBytes }) ?? true else { throw failure() }
            }
            entries = envelope.entries
        } catch { unavailable = true }
    }

    static func key(clientID: String, operationID: UUID) -> String {
        AutomationJSON.hash(Data((clientID + "\u{0}" + operationID.uuidString).utf8))
    }
    func entry(clientID: String, operationID: UUID) throws -> Entry? {
        load()
        guard !unavailable else { throw failure() }
        return entries[Self.key(clientID: clientID, operationID: operationID)]
    }
    func begin(_ entry: Entry) throws {
        load()
        guard !unavailable else { throw failure() }
        guard entries.count < Self.maximumEntries else {
            throw AutomationFailure(code: "journal_full", message: "The automation operation journal is full. No task was changed.")
        }
        let key = Self.key(clientID: entry.clientID, operationID: entry.operationID)
        guard entries[key] == nil else { throw failure() }
        var updated = entries; updated[key] = entry
        try persist(updated, reserve: AutomationJSON.maximumResponseBytes * 2)
        entries = updated
    }
    func finish(_ entry: Entry) throws {
        load()
        guard !unavailable else { throw failure() }
        let key = Self.key(clientID: entry.clientID, operationID: entry.operationID)
        guard entries[key] != nil else { throw failure() }
        var updated = entries; updated[key] = entry
        do { try persist(updated); entries = updated }
        catch {
            // Keep the existing pending record. The caller must not acknowledge
            // success or re-execute a mutation when its outcome was not persisted.
            throw failure()
        }
    }
    /// Only call after the app has revoked this immutable client identity.
    func retireClient(_ clientID: String) throws {
        load()
        guard !unavailable else { throw failure() }
        let retained = entries.filter { $0.value.clientID != clientID }
        guard retained.count != entries.count else { return }
        try persist(retained)
        entries = retained
    }
    private func persist(_ values: [String: Entry], reserve: Int = 0) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(Envelope(version: 1, entries: values))
        guard data.count + reserve <= Self.maximumBytes else {
            throw AutomationFailure(code: "journal_full", message: "The automation operation journal is full. No new operation can start.")
        }
        let directory = url.deletingLastPathComponent()
        let manager = FileManager.default
        do {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let directoryValues = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard directoryValues.isDirectory == true, directoryValues.isSymbolicLink != true else { throw failure() }
            try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            if manager.fileExists(atPath: url.path) {
                let fileValues = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard fileValues.isRegularFile == true, fileValues.isSymbolicLink != true else { throw failure() }
            }
            let temporary = directory.appendingPathComponent(".automation-journal-" + UUID().uuidString)
            let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
            guard descriptor >= 0 else { throw failure() }
            defer { close(descriptor); try? manager.removeItem(at: temporary) }
            try data.withUnsafeBytes { bytes in
                var offset = 0
                while offset < bytes.count {
                    let written = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                    if written < 0, errno == EINTR { continue }
                    guard written > 0 else { throw failure() }
                    offset += written
                }
            }
            guard fsync(descriptor) == 0, Darwin.rename(temporary.path, url.path) == 0 else { throw failure() }
            let directoryDescriptor = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            guard directoryDescriptor >= 0 else { throw failure() }
            defer { close(directoryDescriptor) }
            guard fsync(directoryDescriptor) == 0 else { throw failure() }
        } catch let error as AutomationFailure { throw error }
        catch { throw failure() }
    }
    private func failure() -> AutomationFailure {
        .init(code: "journal_unavailable", message: "The automation operation journal is unavailable. No new task operation will be started.")
    }
}
