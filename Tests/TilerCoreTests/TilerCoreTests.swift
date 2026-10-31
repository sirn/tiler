import XCTest

@testable import TilerCore

final class TilerCoreTests: XCTestCase {
  func testColumnWidthParsesFixedPoints() {
    XCTAssertEqual(ColumnWidth.parseFixed("900px"), 900)
    XCTAssertEqual(ColumnWidth.parseFixed("640"), 640)
    XCTAssertNil(ColumnWidth.parseFixed("900em"))
    XCTAssertNil(ColumnWidth.parseFixed("0px"))
  }

  // Persisted state stores a proportion as a number and a fixed width as "<points>px".
  func testColumnWidthRoundTripsThroughJSON() throws {
    for width in [ColumnWidth.proportion(0.4), ColumnWidth.fixed(880)] {
      let data = try JSONEncoder().encode(width)
      XCTAssertEqual(try JSONDecoder().decode(ColumnWidth.self, from: data), width)
    }
    XCTAssertEqual(String(data: try JSONEncoder().encode(ColumnWidth.proportion(0.4)), encoding: .utf8), "0.4")
    XCTAssertEqual(String(data: try JSONEncoder().encode(ColumnWidth.fixed(880)), encoding: .utf8), "\"880px\"")
  }

  func testWorkspaceInit() {
    let workspace = Workspace(id: 1)
    XCTAssertEqual(workspace.id, 1)
    XCTAssertTrue(workspace.columns.isEmpty)
    XCTAssertEqual(workspace.focusedColumnIndex, 0)
  }
}
