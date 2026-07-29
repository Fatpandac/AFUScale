import XCTest
@testable import AFUScale

final class ShortcutURLTests: XCTestCase {
    func testBuildsRunShortcutURLWithJSONPayload() throws {
        let url = try XCTUnwrap(ScaleController.shortcutURL(name: "记体重", weight: 68.653, bmi: 23.21, fat: 18.74))
        let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }

        XCTAssertEqual(url.scheme, "shortcuts")
        XCTAssertEqual(url.host, "x-callback-url")
        XCTAssertEqual(url.path, "/run-shortcut")
        XCTAssertEqual(value("x-success"), "afuscale://saved")
        XCTAssertEqual(value("x-error"), "afuscale://failed")
        XCTAssertEqual(value("x-cancel"), "afuscale://cancelled")
        XCTAssertEqual(value("name"), "记体重")
        XCTAssertEqual(value("input"), "text")
        // 体脂率以百分数传递（两位小数），不是 0.1874，也不是 1874。
        XCTAssertEqual(value("text"), #"{"weight":68.65,"bmi":23.21,"fat":18.74}"#)
    }
}
