import XCTest

@testable import TilerCore

final class TilerCoreTests: XCTestCase {
  func testWorkspaceInit() {
    let workspace = Workspace(id: 1)
    XCTAssertEqual(workspace.id, 1)
    XCTAssertTrue(workspace.columns.isEmpty)
    XCTAssertEqual(workspace.focusedColumnIndex, 0)
  }
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
    let cols = [Column(windows: [w1, w2], focusedWindowIndex: 1)]
    let result = consumeOrExpel(columns: cols, focusedColumnIndex: 0, direction: .right)
    XCTAssertNotNil(result)
    XCTAssertEqual(result!.columns.count, 2)
    XCTAssertEqual(result!.columns[0].windows, [w1])
    XCTAssertEqual(result!.columns[1].windows, [w2])
    XCTAssertEqual(result!.focusedColumnIndex, 1)
  }

  func testExpelStackedToLeft() {
    let cols = [Column(windows: [w1, w2], focusedWindowIndex: 1)]
    let result = consumeOrExpel(columns: cols, focusedColumnIndex: 0, direction: .left)
    XCTAssertNotNil(result)
    XCTAssertEqual(result!.columns.count, 2)
    XCTAssertEqual(result!.columns[0].windows, [w2])
    XCTAssertEqual(result!.columns[1].windows, [w1])
    XCTAssertEqual(result!.focusedColumnIndex, 0)
  }

  func testConsumeNoLeftNeighborIsNoop() {
    let cols = [
      Column(windows: [w1], focusedWindowIndex: 0),
      Column(windows: [w2], focusedWindowIndex: 0),
    ]
    let result = consumeOrExpel(columns: cols, focusedColumnIndex: 0, direction: .left)
    XCTAssertNil(result)
  }

  func testConsumeNoRightNeighborIsNoop() {
    let cols = [
      Column(windows: [w1], focusedWindowIndex: 0),
      Column(windows: [w2], focusedWindowIndex: 0),
    ]
    let result = consumeOrExpel(columns: cols, focusedColumnIndex: 1, direction: .right)
    XCTAssertNil(result)
  }

  func testRoundTripConsumeThenExpel() {
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
