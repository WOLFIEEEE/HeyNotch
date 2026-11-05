import Combine
import Darwin
import Foundation

struct MeetingHistoryEntry: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let startedAt: Date
    var updatedAt: Date
    var title: String
    let callSource: String
    let elapsed: TimeInterval
    let completed: Bool
    let segments: [MeetingTranscriptSegment]
}

/// Opt-in, device-local transcript history. Main-actor serialization prevents
/// incremental snapshots, rename, retention and explicit deletion from racing.
/// No raw audio, credentials, provider context or call contents outside the
/// supplied transcript are persisted.
@MainActor
final class MeetingHistoryStore: ObservableObject {
    static let shared = MeetingHistoryStore(directory: defaultDirectory)
    static let preferenceKey = "meetings.keepHistory"
    static let maximumFileBytes = 2 * 1024 * 1024
    static let maximumEntries = 50
    static let retention: TimeInterval = 30 * 24 * 60 * 60
    static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HeyNotch/MeetingHistory", isDirectory: true)
    }

    @Published private(set) var enabled: Bool
    @Published private(set) var entries: [MeetingHistoryEntry] = []
    @Published private(set) var errorMessage: String?
    private let directory: URL
    private let defaults: UserDefaults
    private let now: () -> Date
    private let files = FileManager.default
    private var blockedIDs: Set<UUID> = []
    private var suppressedIDs: Set<UUID> = []
    private var blockedDirectory = false
    private struct Envelope: Codable { let version: Int; let entry: MeetingHistoryEntry }
    private enum Failure: Error { case unreadable, invalid, write, protectedFile }

    init(directory: URL, defaults: UserDefaults = .standard, now: @escaping () -> Date = Date.init) {
        self.directory = directory; self.defaults = defaults; self.now = now
        enabled = defaults.bool(forKey: Self.preferenceKey)
        reload()
    }

    func setEnabled(_ value: Bool) {
        enabled = value; defaults.set(value, forKey: Self.preferenceKey)
        // Disabling new snapshots does not immediately erase retained history.
        // Normal expiry still runs the next time history is loaded.
        if value { reload() }
    }
    func dismissError() { errorMessage = nil }
    func contains(id: UUID) -> Bool { entries.contains { $0.id == id } }

    func reload() {
        entries = []; blockedIDs = []; blockedDirectory = false; errorMessage = nil
        guard files.fileExists(atPath: directory.path) else { return }
        do {
            try validateDirectory()
            let contents = try files.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            for url in contents where isTemporarySnapshot(url) { try removeOwnedFile(url) }
            let urls = contents.filter { $0.pathExtension == "json" }
            guard urls.count <= 500 else { throw Failure.unreadable }
            for url in urls {
                guard let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent) else {
                    errorMessage = "An unrecognized meeting-history file was left untouched. Review the history folder before continuing."
                    blockedDirectory = true; continue
                }
                do {
                    let entry = try read(url, expectedID: id)
                    // Suppression prevents a future autosave from resurrecting
                    // a deleted session. It must not hide a file whose deletion
                    // failed, otherwise the user cannot see it or retry removal.
                    entries.append(entry)
                } catch {
                    blockedIDs.insert(id)
                    errorMessage = "Some meeting history could not be read or exceeds the size limit. Those files were left untouched; delete the affected history or clear history before replacing it."
                }
            }
            sortEntries()
            if !blockedDirectory { try prune() }
        } catch {
            blockedDirectory = true
            errorMessage = "Meeting history could not be opened. Existing files were left untouched. Check the folder’s permissions and try again."
        }
    }

    @discardableResult
    func upsert(_ snapshot: MeetingHistoryEntry) -> Bool {
        guard enabled, !suppressedIDs.contains(snapshot.id) else { return false }
        guard !blockedDirectory, !blockedIDs.contains(snapshot.id) else {
            errorMessage = "This meeting history could not be read safely and will not be overwritten. Delete it explicitly before replacing it."
            return false
        }
        do {
            let prior = entries.first { $0.id == snapshot.id }
            let entry = MeetingHistoryEntry(id: snapshot.id, startedAt: prior?.startedAt ?? snapshot.startedAt,
                updatedAt: snapshot.updatedAt, title: prior?.title ?? snapshot.title,
                callSource: snapshot.callSource, elapsed: snapshot.elapsed, completed: snapshot.completed, segments: snapshot.segments)
            try validate(entry)
            guard now().timeIntervalSince(entry.startedAt) < Self.retention else {
                if prior != nil { try removeFile(id: entry.id); entries.removeAll { $0.id == entry.id } }
                return false
            }
            try write(entry)
            entries.removeAll { $0.id == entry.id }; entries.append(entry); sortEntries()
            try prune()
            if blockedIDs.isEmpty { errorMessage = nil }
            return contains(id: entry.id)
        } catch {
            errorMessage = "The meeting transcript could not be saved to history. The in-memory transcript is still available to copy or save. Check free space and folder permissions."
            return false
        }
    }

    @discardableResult
    func rename(id: UUID, title: String) -> Bool {
        guard var entry = entries.first(where: { $0.id == id }), !blockedDirectory, !blockedIDs.contains(id) else { return false }
        let value = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard validTitle(value) else { errorMessage = "Use a meeting title of 1–120 characters without line breaks or control characters."; return false }
        entry.title = value; entry.updatedAt = now()
        do {
            try write(entry)
            entries.removeAll { $0.id == id }; entries.append(entry); sortEntries()
            errorMessage = nil; return true
        } catch {
            errorMessage = "The meeting title could not be saved. The previous title was kept."; return false
        }
    }

    /// Deletion is permitted while history is disabled. Suppression prevents an
    /// in-flight recording's next snapshot from resurrecting an explicitly deleted session.
    @discardableResult
    func delete(id: UUID) -> Bool {
        suppressedIDs.insert(id)
        do {
            try removeFile(id: id)
            entries.removeAll { $0.id == id }; blockedIDs.remove(id)
            errorMessage = nil; return true
        } catch {
            errorMessage = "This meeting history could not be deleted. Check folder permissions and try again."; return false
        }
    }

    @discardableResult
    func clear() -> Bool {
        suppressedIDs.formUnion(entries.map(\.id)); suppressedIDs.formUnion(blockedIDs)
        guard files.fileExists(atPath: directory.path) else { entries = []; errorMessage = nil; return true }
        do {
            try validateDirectory()
            // Clear only our session files, including corrupt session JSON.
            // Never recursively remove an arbitrary folder or follow symlinks.
            for url in try files.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) where isSessionFile(url) || isTemporarySnapshot(url) {
                if let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent) { suppressedIDs.insert(id) }
                try removeOwnedFile(url)
            }
            // Unknown files belong to neither the session format nor our atomic
            // writer. Preserve them and keep any resulting warning/block visible.
            reload(); return true
        } catch {
            reload(); errorMessage = "Some meeting history could not be deleted. Check folder permissions and try again."; return false
        }
    }

    private func path(_ id: UUID) -> URL { directory.appendingPathComponent(id.uuidString + ".json") }
    private func isSessionFile(_ url: URL) -> Bool {
        url.pathExtension == "json" && UUID(uuidString: url.deletingPathExtension().lastPathComponent) != nil
    }
    private func isTemporarySnapshot(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        return name.hasPrefix(".snapshot-") && UUID(uuidString: String(name.dropFirst(".snapshot-".count))) != nil
    }
    private func validTitle(_ title: String) -> Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && title.count <= 120 &&
        !title.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) || CharacterSet.newlines.contains($0) }
    }
    private func validate(_ entry: MeetingHistoryEntry) throws {
        guard validTitle(entry.title), entry.callSource.utf8.count <= 2048,
              entry.startedAt.timeIntervalSince1970.isFinite, entry.updatedAt.timeIntervalSince1970.isFinite,
              entry.startedAt <= now().addingTimeInterval(300), entry.updatedAt <= now().addingTimeInterval(300),
              entry.elapsed.isFinite, (0...86_400).contains(entry.elapsed), entry.segments.count <= 2000,
              Set(entry.segments.map(\.id)).count == entry.segments.count,
              entry.segments.allSatisfy({ $0.offset.isFinite && (0...86_400).contains($0.offset) && $0.text.utf8.count <= 65_536 }) else { throw Failure.invalid }
    }
    private func validateDirectory() throws {
        let attributes = try files.attributesOfItem(atPath: directory.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory else { throw Failure.protectedFile }
    }
    private func prepareDirectory() throws {
        if !files.fileExists(atPath: directory.path) {
            try files.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        try validateDirectory()
        try files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }
    private func read(_ url: URL, expectedID: UUID) throws -> MeetingHistoryEntry {
        let attributes = try files.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber, size.intValue <= Self.maximumFileBytes else { throw Failure.unreadable }
        let data = try Data(contentsOf: url)
        guard data.count <= Self.maximumFileBytes else { throw Failure.unreadable }
        let value = try JSONDecoder().decode(Envelope.self, from: data)
        guard value.version == 1, value.entry.id == expectedID else { throw Failure.invalid }
        try validate(value.entry); return value.entry
    }
    private func write(_ entry: MeetingHistoryEntry) throws {
        try validate(entry)
        let data = try JSONEncoder().encode(Envelope(version: 1, entry: entry))
        guard data.count <= Self.maximumFileBytes else { throw Failure.invalid }
        try prepareDirectory()
        let destination = path(entry.id)
        if files.fileExists(atPath: destination.path) {
            // Recheck on disk immediately before replacement: a file that became
            // corrupt after reload must not be silently overwritten by autosave.
            _ = try read(destination, expectedID: entry.id)
        }
        let temporary = directory.appendingPathComponent(".snapshot-" + UUID().uuidString)
        defer { try? files.removeItem(at: temporary) }
        guard files.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600]) else { throw Failure.write }
        // Same-directory POSIX rename atomically installs a fully written 0600
        // file, without exposing a partially written destination to recovery.
        guard Darwin.rename(temporary.path, destination.path) == 0 else { throw Failure.write }
    }
    private func removeFile(id: UUID) throws {
        guard files.fileExists(atPath: directory.path) else { return }
        try validateDirectory()
        let url = path(id)
        if files.fileExists(atPath: url.path) || (try? files.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType) == .typeSymbolicLink {
            try removeOwnedFile(url)
        }
    }
    private func removeOwnedFile(_ url: URL) throws {
        let type = try files.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType
        guard type == .typeRegular || type == .typeSymbolicLink else { throw Failure.protectedFile }
        try files.removeItem(at: url)
    }
    private func prune() throws {
        let cutoff = now().addingTimeInterval(-Self.retention)
        let retained = entries.filter { $0.startedAt > cutoff }.sorted(by: Self.newestFirst)
        let keep = Set(retained.prefix(Self.maximumEntries).map(\.id))
        for entry in entries where !keep.contains(entry.id) { try removeFile(id: entry.id) }
        entries.removeAll { !keep.contains($0.id) }; sortEntries()
    }
    private static func newestFirst(_ lhs: MeetingHistoryEntry, _ rhs: MeetingHistoryEntry) -> Bool {
        lhs.updatedAt == rhs.updatedAt ? lhs.id.uuidString < rhs.id.uuidString : lhs.updatedAt > rhs.updatedAt
    }
    private func sortEntries() { entries.sort(by: Self.newestFirst) }
}
