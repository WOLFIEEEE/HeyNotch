import AppKit
import Foundation

/// Transfer content is independent of the shelf's shortened display labels.
struct ShelfTransferPayload {
    enum Value: Equatable {
        case file(URL)
        case text(String)
        case link(URL)
    }

    let values: [Value]

    init<Item: Identifiable>(clicked: Item, selected: [Item], resolve: (Item) -> Value?) {
        let items = selected.contains { $0.id == clicked.id } ? selected : [clicked]
        values = items.compactMap(resolve)
    }

    var fileURLs: [URL] {
        values.compactMap { value in
            if case .file(let url) = value { return url }
            return nil
        }
    }

    var sharingItems: [Any] {
        values.map { value in
            switch value {
            case .file(let url), .link(let url): return url
            case .text(let text): return text
            }
        }
    }

    @MainActor
    func pasteboardItems() -> [any NSPasteboardWriting] {
        let textValues = values.compactMap { value -> String? in
            switch value {
            case .text(let text): return text
            case .link(let url): return url.absoluteString
            case .file: return nil
            }
        }
        var result: [any NSPasteboardWriting] = []
        if !textValues.isEmpty {
            // One text item lets plain-text consumers paste the entire selection.
            // Keep its original whitespace and URL schemes; only separators are added.
            let item = NSPasteboardItem()
            item.setString(textValues.joined(separator: "\n"), forType: .string)
            if values.count == 1, case .link(let url) = values[0] {
                item.setString(url.absoluteString, forType: .URL)
            }
            result.append(item)
        }
        for url in fileURLs {
            // Let AppKit serialize native file URLs after the caller starts
            // security-scoped access, including its normal access metadata.
            result.append(url as NSURL)
        }
        return result
    }
}
