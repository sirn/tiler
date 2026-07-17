import AppKit
import Foundation

public struct LayoutContext {
  public let screen: ScreenInfo
  public let gaps: GapConfig
  public let centerFocusedColumn: CenterFocusedColumn

  public init(
    screen: ScreenInfo, gaps: GapConfig,
    centerFocusedColumn: CenterFocusedColumn = .never
  ) {
    self.screen = screen
    self.gaps = gaps
    self.centerFocusedColumn = centerFocusedColumn
  }
}

public struct ResolvedLayout {
  public let offset: CGFloat
  public let visibleRange: Range<Int>
  public let frames: [CGWindowID: NSRect]

  public init(offset: CGFloat, visibleRange: Range<Int>, frames: [CGWindowID: NSRect]) {
    self.offset = offset
    self.visibleRange = visibleRange
    self.frames = frames
  }
}

public enum LayoutResolver {
  public static func resolve(_ workspace: Workspace, _ context: LayoutContext) -> ResolvedLayout {
    let cols = LayoutGeometry.columns(workspace, context.screen, context.gaps)
    let U = LayoutGeometry.usableWidth(context.screen, context.gaps)
    let (offset, visible) = ViewportCalc.resolveOffset(
      anchor: workspace.scrollOffset,
      focused: workspace.focusedColumnIndex,
      strip: cols,
      U: U,
      centerMode: context.centerFocusedColumn
    )
    let frames = LayoutEngine.layout(
      workspace: workspace,
      screen: context.screen,
      gaps: context.gaps,
      viewportOffset: offset,
      visibleRange: visible
    )
    return ResolvedLayout(offset: offset, visibleRange: visible, frames: frames)
  }
}
