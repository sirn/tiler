import Foundation

public struct Workspace: Equatable {
    public var id: WorkspaceID
    public var columns: [Column]
    public var focusedColumnIndex: Int
    
    public init(id: WorkspaceID, columns: [Column] = [], focusedColumnIndex: Int = 0) {
        self.id = id
        self.columns = columns
        self.focusedColumnIndex = focusedColumnIndex
    }
}
