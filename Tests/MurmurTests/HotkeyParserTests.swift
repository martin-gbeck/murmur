import Carbon.HIToolbox
import Testing
@testable import Murmur

@Suite struct HotkeyParserTests {
    @Test func defaultChord() throws {
        let spec = try HotkeyManager.parse("ctrl+alt+space")
        #expect(spec.keyCode == UInt32(kVK_Space))
        #expect(spec.carbonModifiers == UInt32(controlKey) | UInt32(optionKey))
    }

    @Test func modifierAliases() throws {
        let a = try HotkeyManager.parse("control+option+space")
        let b = try HotkeyManager.parse("ctrl+alt+space")
        #expect(a == b)
    }

    @Test func allFourModifiers() throws {
        let spec = try HotkeyManager.parse("cmd+shift+ctrl+alt+d")
        #expect(spec.keyCode == UInt32(kVK_ANSI_D))
        #expect(
            spec.carbonModifiers ==
            UInt32(cmdKey) | UInt32(shiftKey) | UInt32(controlKey) | UInt32(optionKey)
        )
    }

    @Test func letterDigitAndFunctionKeys() throws {
        #expect(try HotkeyManager.parse("cmd+m").keyCode == UInt32(kVK_ANSI_M))
        #expect(try HotkeyManager.parse("cmd+7").keyCode == UInt32(kVK_ANSI_7))
        #expect(try HotkeyManager.parse("f5").keyCode == UInt32(kVK_F5))
        #expect(try HotkeyManager.parse("f19").keyCode == UInt32(kVK_F19))
    }

    @Test func caseAndWhitespaceInsensitive() throws {
        let spec = try HotkeyManager.parse(" Ctrl + Alt + Space ")
        #expect(spec.keyCode == UInt32(kVK_Space))
    }

    @Test func unknownTokenThrows() {
        #expect(throws: (any Error).self) { try HotkeyManager.parse("ctrl+banana") }
    }

    @Test func modifiersWithoutKeyThrows() {
        #expect(throws: (any Error).self) { try HotkeyManager.parse("ctrl+alt") }
    }

    @Test func twoKeysThrows() {
        #expect(throws: (any Error).self) { try HotkeyManager.parse("a+b") }
    }

    @Test func emptyThrows() {
        #expect(throws: (any Error).self) { try HotkeyManager.parse("") }
    }

    @Test func displayString() {
        #expect(HotkeyManager.displayString("ctrl+alt+space") == "⌃⌥Space")
        #expect(HotkeyManager.displayString("cmd+shift+d") == "⇧⌘D")
        #expect(HotkeyManager.displayString("f5") == "F5")
        // Unparseable chords come back unchanged instead of crashing the menu.
        #expect(HotkeyManager.displayString("ctrl+alt") == "ctrl+alt")
    }

    @Test func keyNameRoundTrip() throws {
        for chord in ["ctrl+a", "cmd+9", "alt+space", "f12"] {
            let spec = try HotkeyManager.parse(chord)
            let name = HotkeyManager.keyName(forKeyCode: spec.keyCode)
            #expect(name == chord.split(separator: "+").last.map(String.init))
        }
    }
}
