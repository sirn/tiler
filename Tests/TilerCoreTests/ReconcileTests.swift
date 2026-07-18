import XCTest

@testable import TilerCore

final class ReconcileTests: XCTestCase {

  // MARK: - classifyGeometryChange tests

  func testEchoExactMatch() {
    let rect = NSRect(x: 10, y: 20, width: 300, height: 200)
    XCTAssertEqual(classifyGeometryChange(observed: rect, applied: rect, tolerance: 2.0), .echo)
  }

  func testEchoWithinTolerance() {
    let applied = NSRect(x: 10, y: 20, width: 300, height: 200)
    let observed = NSRect(x: 10 + 1.9, y: 20, width: 300, height: 200)
    XCTAssertEqual(
      classifyGeometryChange(observed: observed, applied: applied, tolerance: 2.0), .echo)
  }

  func testEchoAtToleranceBoundaryIsGenuine() {
    let applied = NSRect(x: 10, y: 20, width: 300, height: 200)
    let observed = NSRect(x: 10 + 2.0, y: 20, width: 300, height: 200)
    XCTAssertEqual(
      classifyGeometryChange(observed: observed, applied: applied, tolerance: 2.0), .genuineMove)
  }

  func testGenuineMoveBeyondTolerance() {
    let applied = NSRect(x: 10, y: 20, width: 300, height: 200)
    let observed = NSRect(x: 10 + 3.0, y: 20, width: 300, height: 200)
    XCTAssertEqual(
      classifyGeometryChange(observed: observed, applied: applied, tolerance: 2.0), .genuineMove)
  }

  func testNoRecordIsGenuineMove() {
    let rect = NSRect(x: 10, y: 20, width: 300, height: 200)
    XCTAssertEqual(
      classifyGeometryChange(observed: rect, applied: nil, tolerance: 2.0), .genuineMove)
  }

  // MARK: - reconcilePlan tests

  func testAddNewWindow() {
    let plan = reconcilePlan(
      managedIDs: [1], stillAliveIDs: [1], tileableIDs: [1, 2],
      missingCounts: [:], missThreshold: 2,
      unresolvedIDs: [], resolveCounts: [:], resolveThreshold: 8)
    XCTAssertEqual(plan.toAdd, [2])
    XCTAssertEqual(plan.toReap, [])
  }

  func testReapAfterTwoMisses() {
    let plan = reconcilePlan(
      managedIDs: [1], stillAliveIDs: [], tileableIDs: [],
      missingCounts: [1: 1], missThreshold: 2,
      unresolvedIDs: [], resolveCounts: [:], resolveThreshold: 8)
    XCTAssertEqual(plan.toReap, [1])
    XCTAssertEqual(plan.updatedMissingCounts[1], 2)
  }

  func testTransientMissNotReaped() {
    let plan = reconcilePlan(
      managedIDs: [1], stillAliveIDs: [], tileableIDs: [],
      missingCounts: [:], missThreshold: 2,
      unresolvedIDs: [], resolveCounts: [:], resolveThreshold: 8)
    XCTAssertEqual(plan.toReap, [])
    XCTAssertEqual(plan.updatedMissingCounts[1], 1)
    XCTAssertTrue(plan.hasPendingMiss)
  }

  func testReappearResetsMissCount() {
    let plan = reconcilePlan(
      managedIDs: [1], stillAliveIDs: [1], tileableIDs: [1],
      missingCounts: [1: 1], missThreshold: 2,
      unresolvedIDs: [], resolveCounts: [:], resolveThreshold: 8)
    XCTAssertEqual(plan.updatedMissingCounts[1], 0)
    XCTAssertEqual(plan.toReap, [])
    XCTAssertFalse(plan.hasPendingMiss)
  }

  func testOffscreenParkedNotReapedIfStillTileable() {
    let plan = reconcilePlan(
      managedIDs: [1], stillAliveIDs: [1], tileableIDs: [],
      missingCounts: [:], missThreshold: 2,
      unresolvedIDs: [], resolveCounts: [:], resolveThreshold: 8)
    XCTAssertEqual(plan.toReap, [])
    XCTAssertEqual(plan.toAdd, [])
  }

  func testMissingCountsPrunedForRemovedIds() {
    let plan = reconcilePlan(
      managedIDs: [], stillAliveIDs: [], tileableIDs: [],
      missingCounts: [9: 1], missThreshold: 2,
      unresolvedIDs: [], resolveCounts: [:], resolveThreshold: 8)
    XCTAssertNil(plan.updatedMissingCounts[9])
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

  // MARK: - native fullscreen Space regression
  // When a window enters native macOS fullscreen, every window on the regular Space
  // vanishes from the on-screen CGWindowList for the whole fullscreen duration. The
  // WindowManager fix keeps those windows in stillAliveIDs (they are hidden by the Space
  // switch, not closed/minimized). These tests pin the contract reconcilePlan relies on:
  // stillAlive windows are never reaped, even over a long fullscreen session, while the
  // same windows dropped from stillAliveIDs (the pre-fix bug) are reaped after the
  // threshold — which discarded their column assignments and widths on fullscreen exit.

  func testFullscreenSpaceHiddenWindowsSurviveAcrossPasses() {
    let hidden: Set<CGWindowID> = [670, 8212, 11469, 11791, 12065, 12091, 14728, 15099, 15647]
    var counts: [CGWindowID: Int] = [:]
    for _ in 0..<150 {
      let plan = reconcilePlan(
        managedIDs: hidden, stillAliveIDs: hidden, tileableIDs: [],
        missingCounts: counts, missThreshold: 2)
      XCTAssertEqual(plan.toReap, [])
      counts = plan.updatedMissingCounts
    }
    XCTAssertTrue(counts.values.allSatisfy { $0 == 0 })
  }

  func testFullscreenSpaceHiddenWindowsReapedIfDroppedFromStillAlive() {
    let hidden: Set<CGWindowID> = [670, 8212, 11469, 11791, 12065, 12091, 14728, 15099, 15647]
    var counts: [CGWindowID: Int] = [:]
    var reaped: Set<CGWindowID> = []
    // Pre-fix behavior: Space-hidden windows were absent from stillAlive, so each pass
    // incremented their miss count until the threshold reaped them — well within a
    // typical fullscreen session.
    for _ in 0..<3 {
      let plan = reconcilePlan(
        managedIDs: hidden, stillAliveIDs: [], tileableIDs: [],
        missingCounts: counts, missThreshold: 2)
      reaped = plan.toReap
      counts = plan.updatedMissingCounts
    }
    XCTAssertEqual(reaped, hidden)
  }
}
