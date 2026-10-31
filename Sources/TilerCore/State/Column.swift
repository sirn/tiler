import Foundation

/// Column width, mirroring Niri's `ColumnWidth`: either a proportion of the space
/// columns share, or a fixed width in points.
public enum ColumnWidth: Equatable {
  case proportion(CGFloat)
  case fixed(CGFloat)

  /// Parses a fixed width such as `"900px"` (or a bare `"900"`). Returns nil for
  /// anything that is not a positive pixel count.
  public static func parseFixed(_ text: String) -> CGFloat? {
    var digits = Substring(text.trimmingCharacters(in: .whitespaces))
    if digits.hasSuffix("px") { digits = digits.dropLast(2) }
    guard let value = Double(digits), value > 0 else { return nil }
    return CGFloat(value)
  }
}

extension ColumnWidth: Codable {
  public init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    if let number = try? container.decode(Double.self) {
      self = .proportion(CGFloat(number))
      return
    }
    let text = try container.decode(String.self)
    guard let points = ColumnWidth.parseFixed(text) else {
      throw DecodingError.dataCorruptedError(
        in: container, debugDescription: "expects a fraction or \"<points>px\", got \"\(text)\"")
    }
    self = .fixed(points)
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .proportion(let proportion):
      try container.encode(Double(proportion))
    case .fixed(let points):
      try container.encode("\(Int(points.rounded()))px")
    }
  }
}

public struct Column: Identifiable, Equatable {
  public enum ColumnMode: Equatable {
    case stack
    case tab
  }

  public let id: UUID
  public var windows: [WindowNode]
  public var focusedWindowIndex: Int
  public var mode: ColumnMode
  public var width: ColumnWidth
  // Measured minimum width set by the corrector when a window resists its assigned width
  public var measuredMinWidth: CGFloat?
  public var measuredMinHeight: CGFloat?

  public init(
    id: UUID = UUID(),
    windows: [WindowNode] = [],
    focusedWindowIndex: Int = 0,
    mode: ColumnMode = .stack,
    width: ColumnWidth = .proportion(0.5),
    measuredMinWidth: CGFloat? = nil,
    measuredMinHeight: CGFloat? = nil
  ) {
    self.id = id
    self.windows = windows
    self.focusedWindowIndex = focusedWindowIndex
    self.mode = mode
    self.width = width
    self.measuredMinWidth = measuredMinWidth
    self.measuredMinHeight = measuredMinHeight
  }
}
