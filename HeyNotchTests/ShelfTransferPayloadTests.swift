import AppKit
import XCTest

@MainActor
final class ShelfTransferPayloadTests: XCTestCase {
    private struct Item: Identifiable {
        let id = UUID()
        let value: ShelfTransferPayload.Value?
    }

    private func payload(_ items: [Item], clicked: Item? = nil) -> ShelfTransferPayload {
        ShelfTransferPayload(clicked: clicked ?? items[0], selected: items) { $0.value }
    }

    private func withPasteboard(_ body: (NSPasteboard) throws -> Void) rethrows {
        let pasteboard = NSPasteboard(name: .init("HeyNotchShelfTests.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        try body(pasteboard)
    }

    private func withTemporaryFiles(_ body: ([URL]) throws -> Void) throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("HeyNotchShelfTests.\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let urls = ["first file.txt", "第二 📎.txt"].map { folder.appendingPathComponent($0) }
        for (index, url) in urls.enumerated() {
            try Data("Shelf fixture \(index)".utf8).write(to: url)
        }
        try body(urls)
    }

    func testCopyPreservesLeadingTrailingWhitespaceAndUnicode() throws {
        let text = "  \tCafé 👋\nsecond line\n "
        try withPasteboard { pasteboard in
            XCTAssertTrue(pasteboard.writeObjects(payload([Item(value: .text(text))]).pasteboardItems()))
            XCTAssertEqual(try XCTUnwrap(pasteboard.string(forType: .string)), text)
        }
    }

    func testCopyLinkPreservesSchemeQueryFragmentAndURLType() throws {
        let url = try XCTUnwrap(URL(string: "https://example.invalid/path?q=hello%20world#section"))
        withPasteboard { pasteboard in
            XCTAssertTrue(pasteboard.writeObjects(payload([Item(value: .link(url))]).pasteboardItems()))
            XCTAssertEqual(pasteboard.string(forType: .string), url.absoluteString)
            XCTAssertEqual(pasteboard.string(forType: .URL), url.absoluteString)
        }
    }

    func testCopyMultipleTextItemsKeepsEntirePlainTextSelection() throws {
        let first = "  first\n"
        let second = "\tsecond  "
        let url = try XCTUnwrap(URL(string: "http://example.invalid/path#fragment"))
        withPasteboard { pasteboard in
            let result = payload([Item(value: .text(first)), Item(value: .link(url)), Item(value: .text(second))])
            XCTAssertTrue(pasteboard.writeObjects(result.pasteboardItems()))
            XCTAssertEqual(pasteboard.string(forType: .string), first + "\n" + url.absoluteString + "\n" + second)
            XCTAssertEqual(pasteboard.pasteboardItems?.count, 1)
        }
    }

    func testCopyMixedSelectionRetainsTextLinksAndTypedFileURLs() throws {
        let link = try XCTUnwrap(URL(string: "https://example.invalid/resource?q=1#part"))
        let text = " \n  exact text\t "
        try withTemporaryFiles { urls in
            let result = payload([Item(value: .file(urls[0])), Item(value: .text(text)),
                                  Item(value: .link(link)), Item(value: .file(urls[1]))])
            let writers = result.pasteboardItems()
            XCTAssertEqual(writers.count, 3)
            XCTAssertTrue(writers[0] is NSPasteboardItem)
            XCTAssertTrue(writers.dropFirst().allSatisfy { $0 is NSURL })
            try withPasteboard { pasteboard in
                XCTAssertTrue(pasteboard.writeObjects(writers))
                XCTAssertEqual(pasteboard.string(forType: .string), text + "\n" + link.absoluteString)
                let copiedFiles = try XCTUnwrap(pasteboard.readObjects(forClasses: [NSURL.self],
                    options: [.urlReadingFileURLsOnly: true]) as? [URL])
                XCTAssertEqual(copiedFiles, urls)
                XCTAssertEqual(pasteboard.pasteboardItems?.count, 3)
                for (index, url) in copiedFiles.enumerated() {
                    XCTAssertEqual(try Data(contentsOf: url), Data("Shelf fixture \(index)".utf8))
                }
            }
        }
    }

    func testFileOnlyCopyPreservesEveryFileURL() throws {
        try withTemporaryFiles { urls in
            let result = payload(urls.map { Item(value: .file($0)) })
            let writers = result.pasteboardItems()
            XCTAssertEqual(writers.count, urls.count)
            XCTAssertTrue(writers.allSatisfy { $0 is NSURL })
            try withPasteboard { pasteboard in
                XCTAssertTrue(pasteboard.writeObjects(writers))
                let copiedFiles = try XCTUnwrap(pasteboard.readObjects(forClasses: [NSURL.self],
                    options: [.urlReadingFileURLsOnly: true]) as? [URL])
                XCTAssertEqual(copiedFiles, urls)
                for (index, url) in copiedFiles.enumerated() {
                    XCTAssertEqual(try Data(contentsOf: url), Data("Shelf fixture \(index)".utf8))
                }
            }
        }
    }

    func testShareClickedTextIncludesWholeMixedSelectionInOriginalOrder() throws {
        let text = Item(value: .text("  selected text\n"))
        let url = try XCTUnwrap(URL(string: "https://example.invalid/"))
        let file = URL(fileURLWithPath: "/synthetic/not-created/file")
        let selection = [Item(value: .file(file)), text, Item(value: .link(url))]
        let result = payload(selection, clicked: text)
        XCTAssertEqual(result.values, [.file(file), .text("  selected text\n"), .link(url)])
        XCTAssertEqual(result.sharingItems.count, 3)
        XCTAssertEqual(result.sharingItems[0] as? URL, file)
        XCTAssertEqual(result.sharingItems[1] as? String, "  selected text\n")
        XCTAssertEqual(result.sharingItems[2] as? URL, url)
        XCTAssertEqual(result.fileURLs, [file])
    }

    func testUnselectedClickedItemDoesNotShareUnrelatedSelection() {
        let clicked = Item(value: .text("clicked"))
        let result = payload([Item(value: .text("unrelated"))], clicked: clicked)
        XCTAssertEqual(result.values, [.text("clicked")])
    }

    func testUnresolvedFileDoesNotDiscardOtherSelectedContent() {
        let unavailable = Item(value: nil)
        let result = payload([unavailable, Item(value: .text("keep this"))], clicked: unavailable)
        XCTAssertEqual(result.values, [.text("keep this")])
        XCTAssertEqual(result.pasteboardItems().count, 1)
    }

    func testOnlyUnresolvedFilesProduceNoClipboardWriteItems() {
        let result = payload([Item(value: nil)])
        XCTAssertTrue(result.pasteboardItems().isEmpty)
        XCTAssertTrue(result.sharingItems.isEmpty)
    }
}
