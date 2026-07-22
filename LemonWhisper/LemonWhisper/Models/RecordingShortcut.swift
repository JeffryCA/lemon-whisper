import Carbon
import SwiftUI

/// A user-configurable global shortcut for toggling recording.
struct RecordingShortcut: Codable, Equatable, Hashable {
    var keyCode: UInt32
    var character: String
    var usesCommand: Bool
    var usesShift: Bool
    var usesOption: Bool
    var usesControl: Bool

    /// Matches the shortcut that was previously hardcoded (Ctrl + Y).
    static let `default` = RecordingShortcut(
        keyCode: UInt32(kVK_ANSI_Z),
        character: "y",
        usesCommand: false,
        usesShift: false,
        usesOption: false,
        usesControl: true
    )

    var carbonModifiers: UInt32 {
        var mods: UInt32 = 0
        if usesCommand { mods |= UInt32(cmdKey) }
        if usesShift { mods |= UInt32(shiftKey) }
        if usesOption { mods |= UInt32(optionKey) }
        if usesControl { mods |= UInt32(controlKey) }
        return mods
    }

    var swiftUIModifiers: SwiftUI.EventModifiers {
        var mods: SwiftUI.EventModifiers = []
        if usesCommand { mods.insert(.command) }
        if usesShift { mods.insert(.shift) }
        if usesOption { mods.insert(.option) }
        if usesControl { mods.insert(.control) }
        return mods
    }

    var keyEquivalent: KeyEquivalent {
        KeyEquivalent(character.first ?? "y")
    }

    func conflicts(with other: RecordingShortcut) -> Bool {
        keyCode == other.keyCode && carbonModifiers == other.carbonModifiers
    }

    var displayString: String {
        var symbols = ""
        if usesControl { symbols += "⌃" }
        if usesOption { symbols += "⌥" }
        if usesShift { symbols += "⇧" }
        if usesCommand { symbols += "⌘" }
        symbols += character.uppercased()
        return symbols
    }
}
