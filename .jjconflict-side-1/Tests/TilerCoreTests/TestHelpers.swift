import AppKit
@testable import TilerCore

func makeScreen(width: CGFloat = 1000) -> ScreenInfo {
    ScreenInfo(
        id: 1,
        frame: NSRect(x: 0, y: 0, width: width, height: 800),
        visibleFrame: NSRect(x: 0, y: 0, width: width, height: 800))
}

func makeGaps(column: CGFloat = 8) -> GapConfig {
    GapConfig(outerGaps: 0, innerGaps: 6, columnGaps: column)
}

func makeWorkspace(fractions: [CGFloat], focus: Int) -> Workspace {
    let cols = fractions.map { Column(widthFraction: $0) }
    return Workspace(id: 1, columns: cols, focusedColumnIndex: focus)
}

func makeWorkspaceWithMinWidths(fractions: [CGFloat], minWidths: [CGFloat?], focus: Int) -> Workspace {
    let cols = zip(fractions, minWidths).map { (frac, minW) in
        Column(widthFraction: frac, measuredMinWidth: minW)
    }
    return Workspace(id: 1, columns: cols, focusedColumnIndex: focus)
}
