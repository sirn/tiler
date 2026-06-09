import CoreGraphics
import Foundation

struct PersistedColumn: Codable {
    var windowIDs: [CGWindowID]
    var mode: String
    var widthFraction: CGFloat
    var focusedWindowIndex: Int
}

struct PersistedWorkspace: Codable {
    var columns: [PersistedColumn]
    var focusedColumnIndex: Int
}

struct PersistedScreen: Codable {
    var activeWorkspaceID: WorkspaceID
    var workspaces: [String: PersistedWorkspace]
}

struct PersistedState: Codable {
    var version: Int
    var screens: [String: PersistedScreen]
}

extension PersistedState {
    static func from(_ state: TilerState) -> PersistedState {
        var screens: [String: PersistedScreen] = [:]
        for (screenID, screenState) in state.screens {
            var workspaces: [String: PersistedWorkspace] = [:]
            for (wsID, workspace) in screenState.workspaces {
                let columns = workspace.columns
                    .map { col in
                        PersistedColumn(
                            windowIDs: col.windows.map { $0.id },
                            mode: col.mode == .tab ? "tab" : "stack",
                            widthFraction: col.widthFraction,
                            focusedWindowIndex: col.focusedWindowIndex
                        )
                    }
                    .filter { !$0.windowIDs.isEmpty }
                if !columns.isEmpty || wsID == screenState.activeWorkspaceID {
                    workspaces[String(wsID)] = PersistedWorkspace(
                        columns: columns,
                        focusedColumnIndex: workspace.focusedColumnIndex
                    )
                }
            }
            screens[String(screenID)] = PersistedScreen(
                activeWorkspaceID: screenState.activeWorkspaceID,
                workspaces: workspaces
            )
        }
        return PersistedState(version: 1, screens: screens)
    }
}
