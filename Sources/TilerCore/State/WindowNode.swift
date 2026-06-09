import CoreGraphics

public struct WindowNode: Identifiable, Equatable {

  /// A stable, process-local identity for a tile that survives native-tab backing-id swaps.
  /// Minted once when a window first becomes a tile and carried unchanged through every
  /// id swap / move, so a tab group is tracked as one logical entity even as its active
  /// CGWindowID changes.
  public struct GroupKey: Hashable, Equatable {
    public let value: UInt64
    public init(value: UInt64) { self.value = value }
  }

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
