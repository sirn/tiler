import AppKit
import CoreGraphics
import XCTest

@testable import TilerCore

final class ReducerTests: XCTestCase {

  func makeWindowState(fractions: [CGFloat], focus: Int) -> TilerState {
    let ws = makeWorkspace(fractions: fractions, focus: focus)
    let screen = ScreenState(
      info: makeScreen(),
      workspaces: [1: ws],
      activeWorkspaceID: 1)
    return TilerState(screens: [1: screen])
  }

  func makeEmptyState() -> TilerState {
    let screen = ScreenState(
      info: makeScreen(),
      workspaces: [:],
      activeWorkspaceID: 1)
    return TilerState(screens: [1: screen])
  }

  func env(screenID: ScreenID = 1) -> ReducerEnv {
    ReducerEnv(workspaceCount: 9, activeScreenID: screenID)
  }

  func makeWindowNode(id: UInt32, pid: pid_t = 42, title: String = "win") -> WindowNode {
    WindowNode(id: id, groupKey: WindowNode.GroupKey(value: UInt64(id)), pid: pid, title: title)
  }

  func makeWindowStateWithWindows(windowCounts: [Int], focus: Int) -> TilerState {
    let cols = windowCounts.enumerated().map { i, count in
      let wins = (0..<count).map { j in
        makeWindowNode(id: UInt32(i * 100 + j + 1), title: "win\(i)-\(j)")
      }
      return Column(
        windows: wins, focusedWindowIndex: 0, width: .proportion(1.0 / CGFloat(windowCounts.count)))
    }
    let ws = Workspace(id: 1, columns: cols, focusedColumnIndex: focus)
    let screen = ScreenState(info: makeScreen(), workspaces: [1: ws], activeWorkspaceID: 1)
    return TilerState(screens: [1: screen])
  }

  // MARK: - Focus

  func testFocusColumnRightAdvancesAndEmitsEffects() {
    var state = makeWindowState(fractions: [0.5, 0.5], focus: 0)
    let effects = Reducer.apply(.focusColumnRight, to: &state, env: env())
    XCTAssertEqual(state.screens[1]?.workspaces[1]?.focusedColumnIndex, 1)
    XCTAssertEqual(effects, [.focusFocusedWindow(1, 1), .retile])
  }

  func testFocusColumnRightDoesNotAdvancePastEnd() {
    var state = makeWindowState(fractions: [0.5, 0.5], focus: 1)
    let effects = Reducer.apply(.focusColumnRight, to: &state, env: env())
    XCTAssertEqual(state.screens[1]?.workspaces[1]?.focusedColumnIndex, 1)
    XCTAssertTrue(effects.isEmpty)
  }

  // MARK: - Move column

  func testMoveColumnLeftSwapsAndEmitsRetile() {
    var state = makeWindowState(fractions: [0.5, 0.5], focus: 1)
    let effects = Reducer.apply(.moveColumnLeft, to: &state, env: env())
    XCTAssertEqual(state.screens[1]?.workspaces[1]?.focusedColumnIndex, 0)
    XCTAssertEqual(effects, [.retile])
  }

  // MARK: - Workspace

  func testFocusWorkspaceNoOpWhenSame() {
    var state = makeWindowState(fractions: [0.5], focus: 0)
    let effects = Reducer.apply(.focusWorkspace(1), to: &state, env: env())
    XCTAssertEqual(state.screens[1]?.activeWorkspaceID, 1)
    XCTAssertTrue(effects.isEmpty)
  }

  func testFocusWorkspaceChangesAndLogs() {
    var state = makeWindowState(fractions: [0.5], focus: 0)
    let effects = Reducer.apply(.focusWorkspace(2), to: &state, env: env())
    XCTAssertEqual(state.screens[1]?.activeWorkspaceID, 2)
    XCTAssertEqual(effects, [.retile, .focusFocusedWindow(1, 2), .log("Switched to workspace 2")])
  }

  func testFocusWorkspaceOutOfRange() {
    var state = makeWindowState(fractions: [0.5], focus: 0)
    let effects = Reducer.apply(.focusWorkspace(99), to: &state, env: env())
    XCTAssertEqual(state.screens[1]?.activeWorkspaceID, 1)
    XCTAssertTrue(effects.isEmpty)
  }

  // MARK: - Column focus wrap

  func testFocusColumnLeftWrapsWithinScreen() {
    var state = makeWindowState(fractions: [0.5, 0.5], focus: 0)
    var env = self.env()
    env.focusColumnWrap = true
    let effects = Reducer.apply(.focusColumnLeft, to: &state, env: env)
    XCTAssertEqual(state.screens[1]?.workspaces[1]?.focusedColumnIndex, 1)
    XCTAssertEqual(effects, [.focusFocusedWindow(1, 1), .retile])
  }

  func testFocusColumnRightWrapsWithinScreen() {
    var state = makeWindowState(fractions: [0.5, 0.5], focus: 1)
    var env = self.env()
    env.focusColumnWrap = true
    let effects = Reducer.apply(.focusColumnRight, to: &state, env: env)
    XCTAssertEqual(state.screens[1]?.workspaces[1]?.focusedColumnIndex, 0)
    XCTAssertEqual(effects, [.focusFocusedWindow(1, 1), .retile])
  }

  func testFocusColumnLeftNoWrapIsNoOpAtLeftEdgeSingleScreen() {
    var state = makeWindowState(fractions: [0.5, 0.5], focus: 0)
    let effects = Reducer.apply(.focusColumnLeft, to: &state, env: env())
    XCTAssertEqual(state.screens[1]?.workspaces[1]?.focusedColumnIndex, 0)
    XCTAssertTrue(effects.isEmpty)
  }

  // MARK: - Move to workspace

  func testMoveToWorkspaceTransfersWindow() {
    var state = makeWindowStateWithWindows(windowCounts: [1, 1], focus: 0)
    state.screens[1]?.workspaces[2] = Workspace(id: 2, columns: [], focusedColumnIndex: 0)
    let effects = Reducer.apply(.moveToWorkspace(2), to: &state, env: env())
    // Source should have 1 column now (the other remained)
    XCTAssertEqual(state.screens[1]?.workspaces[1]?.columns.count, 1)
    // Target should have 1 column (transferred window)
    XCTAssertEqual(state.screens[1]?.workspaces[2]?.columns.count, 1)
    XCTAssertEqual(effects, [.retile, .log("Moved window to workspace 2")])
  }

  func testMoveToWorkspaceNoOpToSelf() {
    var state = makeWindowState(fractions: [0.5, 0.5], focus: 0)
    let effects = Reducer.apply(.moveToWorkspace(1), to: &state, env: env())
    // State unchanged
    XCTAssertEqual(state.screens[1]?.workspaces[1]?.columns.count, 2)
    XCTAssertTrue(effects.isEmpty)
  }

  func testMoveToWorkspaceNoOpEmptyColumns() {
    var state = makeEmptyState()
    let effects = Reducer.apply(.moveToWorkspace(2), to: &state, env: env())
    // State unchanged
    XCTAssertTrue(state.screens[1]?.workspaces.isEmpty ?? true)
    XCTAssertTrue(effects.isEmpty)
  }

  func testMoveToWorkspaceRollbackWhenTargetMissing() {
    // Source has a window, target workspace doesn't exist.
    // The mutation to source should NOT be committed.
    let windowCol = Column(
      windows: [makeWindowNode(id: 100)],
      focusedWindowIndex: 0,
      width: .proportion(0.5))
    let ws = Workspace(id: 1, columns: [windowCol], focusedColumnIndex: 0)
    let screen = ScreenState(info: makeScreen(), workspaces: [1: ws], activeWorkspaceID: 1)
    var state = TilerState(screens: [1: screen])
    // No workspace[2] exists — target is missing

    let effects = Reducer.apply(.moveToWorkspace(2), to: &state, env: env())

    // Source should still have its column (no mutation committed)
    XCTAssertEqual(state.screens[1]?.workspaces[1]?.columns.count, 1)
    // No effects — operation was no-op
    XCTAssertTrue(effects.isEmpty)
  }

  // MARK: - Window close

  func testCloseWindowReturnsEffectNoStateMutation() {
    var state = makeWindowStateWithWindows(windowCounts: [1], focus: 0)
    let effects = Reducer.apply(.closeWindow, to: &state, env: env())
    XCTAssertEqual(effects.count, 1)
    if case .closeWindow = effects[0] {
      XCTAssertTrue(true)
    } else {
      XCTFail("Expected .closeWindow effect, got \(effects[0])")
    }
    // State unchanged
    XCTAssertEqual(state.screens[1]?.workspaces[1]?.columns.count, 1)
  }

  // MARK: - Toggle fullscreen

  func testToggleFullscreenReturnsEffectNoStateMutation() {
    var state = makeWindowStateWithWindows(windowCounts: [1], focus: 0)
    let effects = Reducer.apply(.toggleFullscreen, to: &state, env: env())
    XCTAssertEqual(effects.count, 1)
    if case .toggleFullscreen = effects[0] {
      XCTAssertTrue(true)
    } else {
      XCTFail("Expected .toggleFullscreen effect, got \(effects[0])")
    }
    // State unchanged
    XCTAssertEqual(state.screens[1]?.workspaces[1]?.columns.count, 1)
  }

  // MARK: - Column width

  func focusedWidth(_ state: TilerState) -> ColumnWidth? {
    guard let ws = state.screens[1]?.workspaces[1] else { return nil }
    return ws.columns[ws.focusedColumnIndex].width
  }

  func assertProportion(
    _ width: ColumnWidth?, _ expected: CGFloat, file: StaticString = #filePath, line: UInt = #line
  ) {
    guard case .proportion(let p) = width else {
      return XCTFail("expected a proportion, got \(String(describing: width))", file: file, line: line)
    }
    XCTAssertEqual(p, expected, accuracy: 1e-9, file: file, line: line)
  }

  func testIncreaseColumnWidthSnapsToNextStep() {
    var state = makeWindowState(fractions: [0.43], focus: 0)
    _ = Reducer.apply(.increaseColumnWidth, to: &state, env: env())
    assertProportion(focusedWidth(state), 0.45)
  }

  func testDecreaseColumnWidthSnapsToPreviousStep() {
    var state = makeWindowState(fractions: [0.43], focus: 0)
    _ = Reducer.apply(.decreaseColumnWidth, to: &state, env: env())
    assertProportion(focusedWidth(state), 0.40)
  }

  func testColumnWidthOnStepMovesOneStep() {
    var state = makeWindowState(fractions: [0.5], focus: 0)
    _ = Reducer.apply(.increaseColumnWidth, to: &state, env: env())
    assertProportion(focusedWidth(state), 0.55)
    _ = Reducer.apply(.decreaseColumnWidth, to: &state, env: env())
    _ = Reducer.apply(.decreaseColumnWidth, to: &state, env: env())
    assertProportion(focusedWidth(state), 0.45)
  }

  func testIncreaseColumnWidthAboveMaxDoesNotShrink() {
    var state = makeWindowState(fractions: [0.9], focus: 0)
    _ = Reducer.apply(.increaseColumnWidth, to: &state, env: env())
    assertProportion(focusedWidth(state), 0.9)
  }

  func testDecreaseColumnWidthBelowMinDoesNotGrow() {
    var state = makeWindowState(fractions: [0.1], focus: 0)
    _ = Reducer.apply(.decreaseColumnWidth, to: &state, env: env())
    assertProportion(focusedWidth(state), 0.1)
  }

  func testIncreaseColumnWidthBelowMinGrowsToMin() {
    var state = makeWindowState(fractions: [0.1], focus: 0)
    _ = Reducer.apply(.increaseColumnWidth, to: &state, env: env())
    assertProportion(focusedWidth(state), 0.2)
  }

  // MARK: - Consume / expel

  func testConsumeOrExpelLeftExpelsMultiWindowColumn() {
    let multiWinCol = Column(
      windows: [
        makeWindowNode(id: 100, title: "win0"),
        makeWindowNode(id: 101, title: "win1"),
      ],
      focusedWindowIndex: 0,
      width: .proportion(0.5))
    let ws = Workspace(id: 1, columns: [multiWinCol], focusedColumnIndex: 0)
    let screen = ScreenState(info: makeScreen(), workspaces: [1: ws], activeWorkspaceID: 1)
    var state = TilerState(screens: [1: screen])

    let effects = Reducer.apply(.consumeOrExpelLeft, to: &state, env: env())
    XCTAssertEqual(state.screens[1]?.workspaces[1]?.columns.count, 2)
    XCTAssertEqual(
      effects,
      [
        .refreshTabs(1, 1), .scheduleDeferredTabRefresh(1, 1), .raiseTabbedWindows(1, 1),
        .focusFocusedWindow(1, 1), .retile,
      ])
  }

  // MARK: - No-op on invalid state

  func testAllActionsAreNoOpsWhenNoActiveScreen() {
    let actions: [Action] = [
      .focusColumnLeft, .focusColumnRight,
      .moveColumnLeft, .moveColumnRight,
      .focusWindowUp, .focusWindowDown,
      .moveWindowUp, .moveWindowDown,
      .increaseColumnWidth, .decreaseColumnWidth,
      .toggleColumnTabbed, .closeWindow, .toggleFullscreen,
      .focusWorkspace(1), .moveToWorkspace(2),
      .consumeOrExpelLeft, .consumeOrExpelRight,
    ]
    for action in actions {
      var state = makeEmptyState()
      let effects = Reducer.apply(action, to: &state, env: env())
      XCTAssertTrue(effects.isEmpty, "\(action) should be a no-op with no workspace")
    }
  }
}
