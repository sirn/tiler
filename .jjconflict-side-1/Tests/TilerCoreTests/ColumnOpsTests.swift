import XCTest
@testable import TilerCore

final class ColumnOpsTests: XCTestCase {

  // MARK: - consumeOrExpel tests

  func testConsumeLoneIntoLeft() {
    let w1 = WindowNode(id: 1, groupKey: WindowNode.GroupKey(value: 1), pid: 1, title: "w1")
    let w2 = WindowNode(id: 2, groupKey: WindowNode.GroupKey(value: 2), pid: 1, title: "w2")
    var ws = Workspace(id: 1, columns: [
      Column(windows: [w1], focusedWindowIndex: 0),
      Column(windows: [w2], focusedWindowIndex: 0),
    ], focusedColumnIndex: 1)
    XCTAssertTrue(ws.consumeOrExpel(direction: .left))
    XCTAssertEqual(ws.columns.count, 1)
    XCTAssertEqual(ws.columns[0].windows, [w1, w2])
    XCTAssertEqual(ws.focusedColumnIndex, 0)
    XCTAssertEqual(ws.columns[0].focusedWindowIndex, 1)
  }

  func testExpelStackedToRight() {
    let w1 = WindowNode(id: 1, groupKey: WindowNode.GroupKey(value: 1), pid: 1, title: "w1")
    let w2 = WindowNode(id: 2, groupKey: WindowNode.GroupKey(value: 2), pid: 1, title: "w2")
    var ws = Workspace(id: 1, columns: [Column(windows: [w1, w2], focusedWindowIndex: 1)],
                       focusedColumnIndex: 0)
    XCTAssertTrue(ws.consumeOrExpel(direction: .right))
    XCTAssertEqual(ws.columns.count, 2)
    XCTAssertEqual(ws.columns[0].windows, [w1])
    XCTAssertEqual(ws.columns[1].windows, [w2])
    XCTAssertEqual(ws.focusedColumnIndex, 1)
  }

  func testExpelStackedToLeft() {
    let w1 = WindowNode(id: 1, groupKey: WindowNode.GroupKey(value: 1), pid: 1, title: "w1")
    let w2 = WindowNode(id: 2, groupKey: WindowNode.GroupKey(value: 2), pid: 1, title: "w2")
    var ws = Workspace(id: 1, columns: [Column(windows: [w1, w2], focusedWindowIndex: 1)],
                       focusedColumnIndex: 0)
    XCTAssertTrue(ws.consumeOrExpel(direction: .left))
    XCTAssertEqual(ws.columns.count, 2)
    XCTAssertEqual(ws.columns[0].windows, [w2])
    XCTAssertEqual(ws.columns[1].windows, [w1])
    XCTAssertEqual(ws.focusedColumnIndex, 0)
  }

  func testConsumeNoLeftNeighborIsNoop() {
    let w1 = WindowNode(id: 1, groupKey: WindowNode.GroupKey(value: 1), pid: 1, title: "w1")
    let w2 = WindowNode(id: 2, groupKey: WindowNode.GroupKey(value: 2), pid: 1, title: "w2")
    var ws = Workspace(id: 1, columns: [
      Column(windows: [w1], focusedWindowIndex: 0),
      Column(windows: [w2], focusedWindowIndex: 0),
    ], focusedColumnIndex: 0)
    XCTAssertFalse(ws.consumeOrExpel(direction: .left))
  }

  func testConsumeNoRightNeighborIsNoop() {
    let w1 = WindowNode(id: 1, groupKey: WindowNode.GroupKey(value: 1), pid: 1, title: "w1")
    let w2 = WindowNode(id: 2, groupKey: WindowNode.GroupKey(value: 2), pid: 1, title: "w2")
    var ws = Workspace(id: 1, columns: [
      Column(windows: [w1], focusedWindowIndex: 0),
      Column(windows: [w2], focusedWindowIndex: 0),
    ], focusedColumnIndex: 1)
    XCTAssertFalse(ws.consumeOrExpel(direction: .right))
  }

  // MARK: - swapBackingID tests

  func testSwapBackingIDPreservesGroupKey() {
    let g = WindowNode.GroupKey(value: 42)
    var ws = Workspace(id: 1, columns: [
      Column(windows: [WindowNode(id: 100, groupKey: g, pid: 7, title: "old")], widthFraction: 0.5)
    ])
    XCTAssertTrue(ws.swapBackingID(from: 100, to: 200, title: "new"))
    let node = ws.columns[0].windows[0]
    XCTAssertEqual(node.id, 200)        // backing id changed
    XCTAssertEqual(node.groupKey, g)    // stable identity preserved — the invariant
    XCTAssertEqual(node.pid, 7)         // pid preserved
    XCTAssertEqual(node.title, "new")   // title updated
  }

  func testSwapBackingIDPreservesPositionAndOtherTiles() {
    let gA = WindowNode.GroupKey(value: 1)
    let gB = WindowNode.GroupKey(value: 2)
    let columns = [
      Column(
        windows: [
          WindowNode(id: 10, groupKey: gA, pid: 1, title: "a"),
          WindowNode(id: 11, groupKey: gB, pid: 1, title: "b"),
        ], focusedWindowIndex: 1, widthFraction: 0.5)
    ]
    var ws = Workspace(id: 1, columns: columns)
    XCTAssertTrue(ws.swapBackingID(from: 11, to: 99, title: "b2"))
    // First tile untouched
    XCTAssertEqual(ws.columns[0].windows[0].id, 10)
    XCTAssertEqual(ws.columns[0].windows[0].groupKey, gA)
    // Second tile: id swapped in place, groupKey + position preserved
    XCTAssertEqual(ws.columns[0].windows[1].id, 99)
    XCTAssertEqual(ws.columns[0].windows[1].groupKey, gB)
    XCTAssertEqual(ws.columns[0].focusedWindowIndex, 1)
  }

  func testSwapBackingIDNoMatchReturnsNil() {
    let columns = [
      Column(windows: [WindowNode(id: 100, groupKey: WindowNode.GroupKey(value: 1), pid: 1, title: "x")], widthFraction: 0.5)
    ]
    var ws = Workspace(id: 1, columns: columns)
    XCTAssertFalse(ws.swapBackingID(from: 999, to: 200, title: "y"))
  }

  func testRoundTripConsumeThenExpel() {
    let w1 = WindowNode(id: 1, groupKey: WindowNode.GroupKey(value: 1), pid: 1, title: "w1")
    let w2 = WindowNode(id: 2, groupKey: WindowNode.GroupKey(value: 2), pid: 1, title: "w2")
    var ws = Workspace(id: 1, columns: [
      Column(windows: [w1], focusedWindowIndex: 0),
      Column(windows: [w2], focusedWindowIndex: 0),
    ], focusedColumnIndex: 1)
    XCTAssertTrue(ws.consumeOrExpel(direction: .left))
    XCTAssertEqual(ws.columns.count, 1)
    XCTAssertTrue(ws.consumeOrExpel(direction: .right))
    XCTAssertEqual(ws.columns.count, 2)
    XCTAssertEqual(ws.columns[0].windows, [w1])
    XCTAssertEqual(ws.columns[1].windows, [w2])
    XCTAssertEqual(ws.focusedColumnIndex, 1)
  }
}
