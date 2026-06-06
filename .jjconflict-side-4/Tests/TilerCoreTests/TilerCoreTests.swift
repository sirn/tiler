import XCTest

@testable import TilerCore

final class TilerCoreTests: XCTestCase {
  func testWorkspaceInit() {
    let workspace = Workspace(id: 1)
    XCTAssertEqual(workspace.id, 1)
    XCTAssertTrue(workspace.columns.isEmpty)
    XCTAssertEqual(workspace.focusedColumnIndex, 0)
  }
    let win0 = WindowNode(id: 1, groupKey: GroupKey(value: 1), pid: 1, title: "w0")
    let win1 = WindowNode(id: 2, groupKey: GroupKey(value: 2), pid: 1, title: "w1")
    let win2 = WindowNode(id: 3, groupKey: GroupKey(value: 3), pid: 1, title: "w2")
      missingCounts: [:], missThreshold: 2,
      unresolvedIDs: [], resolveCounts: [:], resolveThreshold: 8)
      missingCounts: [1: 1], missThreshold: 2,
      unresolvedIDs: [], resolveCounts: [:], resolveThreshold: 8)
      missingCounts: [:], missThreshold: 2,
      unresolvedIDs: [], resolveCounts: [:], resolveThreshold: 8)
      missingCounts: [1: 1], missThreshold: 2,
      unresolvedIDs: [], resolveCounts: [:], resolveThreshold: 8)
      missingCounts: [:], missThreshold: 2,
      unresolvedIDs: [], resolveCounts: [:], resolveThreshold: 8)
      missingCounts: [9: 1], missThreshold: 2,
      unresolvedIDs: [], resolveCounts: [:], resolveThreshold: 8)
  // MARK: - reconcilePlan resolve-retry tests

  func testUnresolvedIdIncrementsCountAndSetsPendingResolve() {
    let plan = reconcilePlan(
      managedIDs: [], stillAliveIDs: [], tileableIDs: [],
      missingCounts: [:], missThreshold: 2,
      unresolvedIDs: [42], resolveCounts: [:], resolveThreshold: 8)
    XCTAssertEqual(plan.updatedResolveCounts[42], 1)
    XCTAssertTrue(plan.hasPendingResolve)
  }

  func testUnresolvedIdAtThresholdStopsPendingResolve() {
    // count reaches resolveThreshold on this pass (7 + 1 = 8 >= 8)
    let plan = reconcilePlan(
      managedIDs: [], stillAliveIDs: [], tileableIDs: [],
      missingCounts: [:], missThreshold: 2,
      unresolvedIDs: [42], resolveCounts: [42: 7], resolveThreshold: 8)
    XCTAssertEqual(plan.updatedResolveCounts[42], 8)
    XCTAssertFalse(plan.hasPendingResolve)
  }

  func testResolvedIdDropsFromResolveCounts() {
    // id 42 was previously unresolved but is absent from unresolvedIDs this pass
    let plan = reconcilePlan(
      managedIDs: [], stillAliveIDs: [], tileableIDs: [],
      missingCounts: [:], missThreshold: 2,
      unresolvedIDs: [], resolveCounts: [42: 3], resolveThreshold: 8)
    XCTAssertNil(plan.updatedResolveCounts[42])
    XCTAssertFalse(plan.hasPendingResolve)
  }

  func testExistingToAddBehaviorUnaffectedWithEmptyResolveParams() {
    let plan = reconcilePlan(
      managedIDs: [1], stillAliveIDs: [1], tileableIDs: [1, 2],
      missingCounts: [:], missThreshold: 2,
      unresolvedIDs: [], resolveCounts: [:], resolveThreshold: 8)
    XCTAssertEqual(plan.toAdd, [2])
    XCTAssertEqual(plan.toReap, [])
    XCTAssertFalse(plan.hasPendingResolve)
    XCTAssertTrue(plan.updatedResolveCounts.isEmpty)
  }

  // MARK: - consumeOrExpel tests

  func testConsumeLoneIntoLeft() {
    let w1 = WindowNode(id: 1, groupKey: GroupKey(value: 1), pid: 1, title: "w1")
    let w2 = WindowNode(id: 2, groupKey: GroupKey(value: 2), pid: 1, title: "w2")
    let cols = [
      Column(windows: [w1], focusedWindowIndex: 0),
      Column(windows: [w2], focusedWindowIndex: 0),
    ]
    let result = consumeOrExpel(columns: cols, focusedColumnIndex: 1, direction: .left)
    XCTAssertNotNil(result)
    XCTAssertEqual(result!.columns.count, 1)
    XCTAssertEqual(result!.columns[0].windows, [w1, w2])
    XCTAssertEqual(result!.focusedColumnIndex, 0)
    XCTAssertEqual(result!.columns[0].focusedWindowIndex, 1)
  }

  func testExpelStackedToRight() {
    let w1 = WindowNode(id: 1, groupKey: GroupKey(value: 1), pid: 1, title: "w1")
    let w2 = WindowNode(id: 2, groupKey: GroupKey(value: 2), pid: 1, title: "w2")
    let cols = [Column(windows: [w1, w2], focusedWindowIndex: 1)]
    let result = consumeOrExpel(columns: cols, focusedColumnIndex: 0, direction: .right)
    XCTAssertNotNil(result)
    XCTAssertEqual(result!.columns.count, 2)
    XCTAssertEqual(result!.columns[0].windows, [w1])
    XCTAssertEqual(result!.columns[1].windows, [w2])
    XCTAssertEqual(result!.focusedColumnIndex, 1)
  }

  func testExpelStackedToLeft() {
    let w1 = WindowNode(id: 1, groupKey: GroupKey(value: 1), pid: 1, title: "w1")
    let w2 = WindowNode(id: 2, groupKey: GroupKey(value: 2), pid: 1, title: "w2")
    let cols = [Column(windows: [w1, w2], focusedWindowIndex: 1)]
    let result = consumeOrExpel(columns: cols, focusedColumnIndex: 0, direction: .left)
    XCTAssertNotNil(result)
    XCTAssertEqual(result!.columns.count, 2)
    XCTAssertEqual(result!.columns[0].windows, [w2])
    XCTAssertEqual(result!.columns[1].windows, [w1])
    XCTAssertEqual(result!.focusedColumnIndex, 0)
  }

  func testConsumeNoLeftNeighborIsNoop() {
    let w1 = WindowNode(id: 1, groupKey: GroupKey(value: 1), pid: 1, title: "w1")
    let w2 = WindowNode(id: 2, groupKey: GroupKey(value: 2), pid: 1, title: "w2")
    let cols = [
      Column(windows: [w1], focusedWindowIndex: 0),
      Column(windows: [w2], focusedWindowIndex: 0),
    ]
    let result = consumeOrExpel(columns: cols, focusedColumnIndex: 0, direction: .left)
    XCTAssertNil(result)
  }

  func testConsumeNoRightNeighborIsNoop() {
    let w1 = WindowNode(id: 1, groupKey: GroupKey(value: 1), pid: 1, title: "w1")
    let w2 = WindowNode(id: 2, groupKey: GroupKey(value: 2), pid: 1, title: "w2")
    let cols = [
      Column(windows: [w1], focusedWindowIndex: 0),
      Column(windows: [w2], focusedWindowIndex: 0),
    ]
    let result = consumeOrExpel(columns: cols, focusedColumnIndex: 1, direction: .right)
    XCTAssertNil(result)
  }

  // MARK: - swapBackingID tests

  func testSwapBackingIDPreservesGroupKey() {
    let g = GroupKey(value: 42)
    let columns = [
      Column(windows: [WindowNode(id: 100, groupKey: g, pid: 7, title: "old")], widthFraction: 0.5)
    ]
    let result = swapBackingID(in: columns, from: 100, to: 200, title: "new")
    XCTAssertNotNil(result)
    let node = result![0].windows[0]
    XCTAssertEqual(node.id, 200)        // backing id changed
    XCTAssertEqual(node.groupKey, g)    // stable identity preserved — the invariant
    XCTAssertEqual(node.pid, 7)         // pid preserved
    XCTAssertEqual(node.title, "new")   // title updated
  }

  func testSwapBackingIDPreservesPositionAndOtherTiles() {
    let gA = GroupKey(value: 1)
    let gB = GroupKey(value: 2)
    let columns = [
      Column(
        windows: [
          WindowNode(id: 10, groupKey: gA, pid: 1, title: "a"),
          WindowNode(id: 11, groupKey: gB, pid: 1, title: "b"),
        ], focusedWindowIndex: 1, widthFraction: 0.5)
    ]
    let result = swapBackingID(in: columns, from: 11, to: 99, title: "b2")
    XCTAssertNotNil(result)
    // First tile untouched
    XCTAssertEqual(result![0].windows[0].id, 10)
    XCTAssertEqual(result![0].windows[0].groupKey, gA)
    // Second tile: id swapped in place, groupKey + position preserved
    XCTAssertEqual(result![0].windows[1].id, 99)
    XCTAssertEqual(result![0].windows[1].groupKey, gB)
    XCTAssertEqual(result![0].focusedWindowIndex, 1)
  }

  func testSwapBackingIDNoMatchReturnsNil() {
    let columns = [
      Column(windows: [WindowNode(id: 100, groupKey: GroupKey(value: 1), pid: 1, title: "x")], widthFraction: 0.5)
    ]
    XCTAssertNil(swapBackingID(in: columns, from: 999, to: 200, title: "y"))
  }

  func testRoundTripConsumeThenExpel() {
    let w1 = WindowNode(id: 1, groupKey: GroupKey(value: 1), pid: 1, title: "w1")
    let w2 = WindowNode(id: 2, groupKey: GroupKey(value: 2), pid: 1, title: "w2")
    let initial = [
      Column(windows: [w1], focusedWindowIndex: 0),
      Column(windows: [w2], focusedWindowIndex: 0),
    ]
    // Consume col1 into left neighbor → [[w1, w2]], focusedColumnIndex 0
    let consumed = consumeOrExpel(columns: initial, focusedColumnIndex: 1, direction: .left)
    XCTAssertNotNil(consumed)
    // Expel w2 back to the right → [[w1], [w2]], focusedColumnIndex 1
    let expelled = consumeOrExpel(
      columns: consumed!.columns,
      focusedColumnIndex: consumed!.focusedColumnIndex,
      direction: .right)
    XCTAssertNotNil(expelled)
    XCTAssertEqual(expelled!.columns.count, 2)
    XCTAssertEqual(expelled!.columns[0].windows, [w1])
    XCTAssertEqual(expelled!.columns[1].windows, [w2])
    XCTAssertEqual(expelled!.focusedColumnIndex, 1)
  }

}
