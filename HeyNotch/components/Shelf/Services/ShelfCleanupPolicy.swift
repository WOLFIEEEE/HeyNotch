import Foundation

struct ShelfBookmarkSnapshot: Equatable, Sendable {
    let id: UUID
    let bookmark: Data
}

enum ShelfCleanupPolicy {
    static func invalidSnapshots(
        in snapshot: [ShelfBookmarkSnapshot],
        validate: (Data) async -> Bool
    ) async -> [ShelfBookmarkSnapshot] {
        var invalid: [ShelfBookmarkSnapshot] = []
        for item in snapshot {
            guard !Task.isCancelled else { return [] }
            if !(await validate(item.bookmark)) { invalid.append(item) }
        }
        return Task.isCancelled ? [] : invalid
    }

    /// A validation result applies only to the exact bookmark that was checked.
    /// New items and refreshed bookmarks must survive an earlier cleanup pass.
    static func removalIDs(
        current: [ShelfBookmarkSnapshot],
        invalid: [ShelfBookmarkSnapshot]
    ) -> Set<UUID> {
        let invalidByID = Dictionary(invalid.map { ($0.id, $0.bookmark) }, uniquingKeysWith: { _, latest in latest })
        return Set(current.compactMap { item in
            invalidByID[item.id] == item.bookmark ? item.id : nil
        })
    }
}
