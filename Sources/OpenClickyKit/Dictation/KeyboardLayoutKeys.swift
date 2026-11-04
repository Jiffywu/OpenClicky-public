import Carbon.HIToolbox
import CoreGraphics
import Foundation

/// Finds keys by the character they type in the current keyboard layout, so a synthesized Command-V is still
/// "paste" on layouts such as Dvorak, where the key in the QWERTY V position types something else.
public enum KeyboardLayoutKeys {
    /// The virtual key that types `character` in the current layout, with Command held when `withCommand` is true
    /// (layouts like "Dvorak - QWERTY ⌘" switch to QWERTY while Command is down). Nil when the layout has no
    /// Unicode key map (some input methods) or no key types the character. Text Input Sources must be read on
    /// the main thread.
    @MainActor
    public static func keyCode(typing character: Character, withCommand: Bool) -> CGKeyCode? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let property = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(property).takeUnretainedValue() as Data
        let modifiers = withCommand ? UInt32((cmdKey >> 8) & 0xFF) : 0
        let keyboardType = UInt32(LMGetKbdType())
        let wanted = String(character).lowercased()
        return data.withUnsafeBytes { raw -> CGKeyCode? in
            guard let layout = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return nil }
            for code in 0..<128 {
                var deadKeyState: UInt32 = 0
                var characters = [UniChar](repeating: 0, count: 4)
                var length = 0
                let status = UCKeyTranslate(layout, UInt16(code), UInt16(kUCKeyActionDown), modifiers, keyboardType,
                                            OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeyState, characters.count,
                                            &length, &characters)
                guard status == noErr, length > 0 else { continue }
                if String(utf16CodeUnits: characters, count: length).lowercased() == wanted { return CGKeyCode(code) }
            }
            return nil
        }
    }

    /// The key for Command-V in the current layout; the ANSI V position when the layout can't say.
    @MainActor
    public static var pasteKeyCode: CGKeyCode {
        keyCode(typing: "v", withCommand: true) ?? CGKeyCode(kVK_ANSI_V)
    }
}
