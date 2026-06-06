import CoreGraphics

public struct WindowNode: Identifiable, Equatable {
  public let id: CGWindowID
  public let groupKey: GroupKey
  public let pid: pid_t
  public var title: String

  public init(id: CGWindowID, groupKey: GroupKey, pid: pid_t, title: String) {
    self.id = id
    self.groupKey = groupKey
    self.pid = pid
    self.title = title
  }
}
