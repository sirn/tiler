import XCTest
@testable import TilerCore

final class GlobMatchTests: XCTestCase {

  func testExactMatch() {
      XCTAssertTrue(globMatch(pattern: "com.apple.finder", target: "com.apple.finder"))
  }

  func testPrefixWildcard() {
      XCTAssertTrue(globMatch(pattern: "com.apple.*", target: "com.apple.finder"))
      XCTAssertFalse(globMatch(pattern: "com.apple.*", target: "com.google.Chrome"))
  }

  func testSuffixWildcard() {
      XCTAssertTrue(globMatch(pattern: "*.finder", target: "com.apple.finder"))
  }

  func testMiddleWildcard() {
      XCTAssertTrue(globMatch(pattern: "com.*.finder", target: "com.apple.finder"))
  }

  func testMatchAll() {
      XCTAssertTrue(globMatch(pattern: "*", target: "com.apple.finder"))
      XCTAssertTrue(globMatch(pattern: "*", target: ""))
  }

  func testCaseInsensitive() {
      XCTAssertTrue(globMatch(pattern: "COM.APPLE.*", target: "com.apple.finder"))
  }

  func testNoMatch() {
      XCTAssertFalse(globMatch(pattern: "com.apple.finder", target: "com.apple.Safari"))
  }

  func testMultipleStars() {
      XCTAssertTrue(globMatch(pattern: "*apple*", target: "com.apple.finder"))
  }

  func testEmptyPattern() {
      XCTAssertTrue(globMatch(pattern: "", target: ""))
      XCTAssertFalse(globMatch(pattern: "", target: "com.apple.finder"))
  }

  func testTrailingStar() {
      XCTAssertTrue(globMatch(pattern: "com.apple.finder*", target: "com.apple.finder"))
  }

  func testOnlyStars() {
      XCTAssertTrue(globMatch(pattern: "***", target: "anything"))
  }
}
