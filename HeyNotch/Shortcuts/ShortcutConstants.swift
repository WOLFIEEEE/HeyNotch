//
//  Constants.swift
//  HeyNotch
//
//  Created by Richard Kunkli on 16/08/2024.
//

import KeyboardShortcuts
import SwiftUI

extension KeyboardShortcuts.Name {
    static let dictateHold = Self("dictateHold", default: .init(.d, modifiers: [.control, .option, .command]))
    static let dictateToggle = Self("dictateToggle", default: .init(.space, modifiers: [.control, .option]))
    static let voiceTask = Self("voiceTask", default: .init(.t, modifiers: [.control, .option, .command]))
    static let testTextInsertion = Self("testTextInsertion", default: .init(.v, modifiers: [.control, .option, .command]))
    static let clipboardHistoryPanel = Self("clipboardHistoryPanel", default: .init(.c, modifiers: [.shift, .command]))
    static let toggleMicrophone = Self("toggleMicrophone", default: .init(.f5, modifiers: [.function]))
    static let decreaseBacklight = Self("decreaseBacklight", default: .init(.f1, modifiers: [.command]))
    static let increaseBacklight = Self("increaseBacklight", default: .init(.f2, modifiers: [.command]))
    static let toggleSneakPeek = Self("toggleSneakPeek", default: .init(.h, modifiers: [.command, .shift]))
    static let toggleNotchOpen = Self("toggleNotchOpen", default: .init(.i, modifiers: [.command, .shift]))
}
