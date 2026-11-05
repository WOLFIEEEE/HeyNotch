import AppKit
import XCTest

@MainActor
final class InsertionClipboardTests: XCTestCase {
    private func withClipboard(_ body: (NSPasteboard, SystemInsertionEnvironment) throws -> Void) rethrows {
        // Never use the person's general clipboard in automated tests.
        let pasteboard = NSPasteboard(name: .init("HeyNotchTests.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        try body(pasteboard, SystemInsertionEnvironment(pasteboard: pasteboard))
    }

    func testRichTextAndImageBytesSurviveRestoration() throws {
        try withClipboard { pasteboard, environment in
            let richText = NSPasteboardItem()
            richText.setString("original", forType: .string)
            richText.setData(Data("{\\rtf1 original}".utf8), forType: .rtf)
            richText.setString("<b>original</b>", forType: .html)
            let image = NSPasteboardItem()
            image.setData(Data([137, 80, 78, 71, 13, 10, 26, 10]), forType: .png)
            XCTAssertTrue(pasteboard.writeObjects([richText, image]))
            let snapshot = try XCTUnwrap(environment.snapshotClipboard())
            XCTAssertEqual(snapshot.items.count, 2)
            let lease = try XCTUnwrap(environment.writeClipboard("test 👋\nline 2", operationID: UUID(),
                                                                 expectedChangeCount: snapshot.changeCount))
            XCTAssertTrue(environment.ownsClipboard(lease))
            XCTAssertEqual(pasteboard.string(forType: .string), "test 👋\nline 2")
            XCTAssertTrue(environment.restoreClipboard(snapshot, lease: lease))
            XCTAssertEqual(environment.snapshotClipboard()?.items, snapshot.items)
        }
    }

    func testClipboardOwnerChangePreventsRestoration() throws {
        try withClipboard { pasteboard, environment in
            pasteboard.setString("original", forType: .string)
            let snapshot = try XCTUnwrap(environment.snapshotClipboard())
            let lease = try XCTUnwrap(environment.writeClipboard("insertion", operationID: UUID(),
                                                                 expectedChangeCount: snapshot.changeCount))
            pasteboard.clearContents()
            pasteboard.setString("new user copy", forType: .string)
            XCTAssertFalse(environment.ownsClipboard(lease))
            XCTAssertFalse(environment.restoreClipboard(snapshot, lease: lease))
            XCTAssertEqual(pasteboard.string(forType: .string), "new user copy")
        }
    }

    func testStaleGenerationDoesNotOverwriteNewCopy() {
        withClipboard { pasteboard, environment in
            let originalCount = pasteboard.changeCount
            pasteboard.clearContents()
            pasteboard.setString("new copy", forType: .string)
            XCTAssertNil(environment.writeClipboard("insertion", operationID: UUID(), expectedChangeCount: originalCount))
            XCTAssertEqual(pasteboard.string(forType: .string), "new copy")
        }
    }

    func testEmptyClipboardCanBeRestored() throws {
        try withClipboard { pasteboard, environment in
            pasteboard.clearContents()
            let snapshot = try XCTUnwrap(environment.snapshotClipboard())
            let lease = try XCTUnwrap(environment.writeClipboard("insertion", operationID: UUID(),
                                                                 expectedChangeCount: snapshot.changeCount))
            XCTAssertTrue(environment.restoreClipboard(snapshot, lease: lease))
            XCTAssertTrue(pasteboard.pasteboardItems?.isEmpty ?? true)
        }
    }

    func testPromisedDataFailsWithoutChangingClipboard() {
        withClipboard { pasteboard, environment in
            pasteboard.setData(Data([1]), forType: .init("com.apple.pasteboard.promised-file-url"))
            let generation = pasteboard.changeCount
            XCTAssertNil(environment.snapshotClipboard())
            XCTAssertEqual(pasteboard.changeCount, generation)
        }
    }

    func testLargeClipboardFailsWithoutChangingClipboard() {
        withClipboard { pasteboard, environment in
            pasteboard.setData(Data(repeating: 1, count: 16 * 1024 * 1024 + 1), forType: .png)
            let generation = pasteboard.changeCount
            XCTAssertNil(environment.snapshotClipboard())
            XCTAssertEqual(pasteboard.changeCount, generation)
        }
    }
}
