import AppKit

public struct WindowNode: Identifiable, Equatable {
    public let id: CGWindowID
    public let axElement: AXUIElement
    public let pid: pid_t
    public var title: String
    
    public init(id: CGWindowID, axElement: AXUIElement, pid: pid_t, title: String) {
        self.id = id
        self.axElement = axElement
        self.pid = pid
        self.title = title
    }
    
    public static func == (lhs: WindowNode, rhs: WindowNode) -> Bool {
        lhs.id == rhs.id
    }
}
