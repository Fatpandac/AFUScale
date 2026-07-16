import XCTest
@testable import AFUScale

final class BodyMetricsTests: XCTestCase {
    func testCalculatesBmi() {
        XCTAssertEqual(BodyMetrics.bmi(weightKg: 68.65, heightCm: 172), 23.2, accuracy: 0.05)
    }

    func testCalculatesCalibratedBodyFat() {
        let fat = BodyMetrics.bodyFatPercent(weightKg: 68.65, heightCm: 172, age: 24, sex: .male, calibration: 1.5)
        XCTAssertEqual(fat, 18.7, accuracy: 0.05)
    }
}
