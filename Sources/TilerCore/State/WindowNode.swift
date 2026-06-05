import CoreGraphics

public struct WindowNode: Identifiable, Equatable {
    public let id: CGWindowID
    public let pid: pid_t
    public var title: String
    
    public init(id: CGWindowID, pid: pid_t, title: String) {
        self.id = id
        self.pid = pid
        self.title = title
    }
}
