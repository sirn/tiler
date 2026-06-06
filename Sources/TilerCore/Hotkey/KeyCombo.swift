import AppKit
import CoreGraphics

public struct KeyCombo: Equatable, Hashable {
  public var modifiers: CGEventFlags
  public var keyCode: UInt16

  public init(modifiers: CGEventFlags, keyCode: UInt16) {
    self.modifiers = modifiers
    self.keyCode = keyCode
  }

  public func hash(into hasher: inout Hasher) {
    hasher.combine(modifiers.rawValue)
    hasher.combine(keyCode)
  }

  /// Parse a string like "ctrl+alt+h" or "cmd+shift+1" into a KeyCombo.
  /// Returns nil if the string can't be parsed.
  public static func parse(_ string: String) -> KeyCombo? {
    let parts = string.lowercased().split(separator: "+").map(String.init)
    guard let keyPart = parts.last else { return nil }

    var flags: CGEventFlags = []
    for mod in parts.dropLast() {
      switch mod {
      case "cmd", "command": flags.insert(.maskCommand)
      case "ctrl", "control": flags.insert(.maskControl)
      case "alt", "option": flags.insert(.maskAlternate)
      case "shift": flags.insert(.maskShift)
      default: return nil
      }
    }

    guard let keyCode = keyCodeForKey(keyPart) else { return nil }
    return KeyCombo(modifiers: flags, keyCode: keyCode)
  }
}

/// Map key name strings to CGKeyCode values.
private let keyNameToCode: [String: UInt16] = {
  var map: [String: UInt16] = [:]

  // Named keys
  map["left"] = 0x7B  // kVK_LeftArrow
  map["right"] = 0x7C  // kVK_RightArrow
  map["down"] = 0x7D  // kVK_DownArrow
  map["up"] = 0x7E  // kVK_UpArrow
  map["space"] = 0x31  // kVK_Space
  map["return"] = 0x24  // kVK_Return
  map["tab"] = 0x30  // kVK_Tab
  map["escape"] = 0x35  // kVK_Escape
  map["delete"] = 0x33  // kVK_Delete
  map["comma"] = 0x2B  // kVK_ANSI_Comma
  map["period"] = 0x2F  // kVK_ANSI_Period
  map["slash"] = 0x2C  // kVK_ANSI_Slash
  map["semicolon"] = 0x29  // kVK_ANSI_Semicolon
  map["quote"] = 0x27  // kVK_ANSI_Quote
  map["backtick"] = 0x32  // kVK_ANSI_Grave
  map["backslash"] = 0x2A  // kVK_ANSI_Backslash
  map["minus"] = 0x1B  // kVK_ANSI_Minus
  map["equal"] = 0x18  // kVK_ANSI_Equal
  map["bracketleft"] = 0x21  // kVK_ANSI_LeftBracket
  map["bracketright"] = 0x1E  // kVK_ANSI_RightBracket
  map["f1"] = 0x7A
  map["f2"] = 0x78
  map["f3"] = 0x63
  map["f4"] = 0x76
  map["f5"] = 0x60
  map["f6"] = 0x61
  map["f7"] = 0x62
  map["f8"] = 0x64
  map["f9"] = 0x65
  map["f10"] = 0x6D
  map["f11"] = 0x67
  map["f12"] = 0x6F

  return map
}()

private func keyCodeForKey(_ key: String) -> UInt16? {
  // Handle numbers 0-9 with proper kVK mapping (kVK_ANSI_1 through kVK_ANSI_0)
  let numberMap: [String: UInt16] = [
    "1": 18, "2": 19, "3": 20, "4": 21, "5": 23,
    "6": 22, "7": 26, "8": 28, "9": 25, "0": 29,
  ]

  if let num = numberMap[key] {
    return num
  }

  // Handle letters a-z — kVK_ANSI values are NOT sequential
  let letterMap: [String: UInt16] = [
    "a": 0x00, "b": 0x0B, "c": 0x08, "d": 0x02, "e": 0x0E, "f": 0x03,
    "g": 0x05, "h": 0x04, "i": 0x22, "j": 0x26, "k": 0x28, "l": 0x25,
    "m": 0x2E, "n": 0x2D, "o": 0x1F, "p": 0x23, "q": 0x0C, "r": 0x0F,
    "s": 0x01, "t": 0x11, "u": 0x20, "v": 0x09, "w": 0x0D, "x": 0x07,
    "y": 0x10, "z": 0x06,
  ]
  if let code = letterMap[key] {
    return code
  }

  return keyNameToCode[key]
}
