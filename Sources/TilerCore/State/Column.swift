import Foundation

public enum ColumnMode: Equatable {
    case stack
    case tab
}

public struct Column: Identifiable, Equatable {
    public let id: UUID
    public var windows: [WindowNode]
    public var focusedWindowIndex: Int
    public var mode: ColumnMode
    public var widthFraction: CGFloat
    
    public init(id: UUID = UUID(),
                windows: [WindowNode] = [],
                focusedWindowIndex: Int = 0,
                mode: ColumnMode = .stack,
                widthFraction: CGFloat = 0.5) {
        self.id = id
        self.windows = windows
        self.focusedWindowIndex = focusedWindowIndex
        self.mode = mode
        self.widthFraction = widthFraction
    }
}
