import XCTest
@testable import AFUScale

final class ScalePacketParserTests: XCTestCase {
    func testParsesRealtimeWeightPacket() throws {
        let data = Data(hex: "ac 29 80 69 0f e0 02 00 05 40 00 64 00 00 00 00 00 29 d5 06")
        let result = try XCTUnwrap(ScalePacketParser.parse(data))
        XCTAssertEqual(result.weightKg, 69.6, accuracy: 0.001)
        XCTAssertTrue(result.isStable)
        XCTAssertFalse(result.isFinal)
        XCTAssertNil(result.impedance)
    }

    func testParsesFinalResultPacketWithImpedance() throws {
        let data = Data(hex: "ac 29 02 00 01 e2 01 b0 01 80 69 0f e0 00 00 00 00 29 d6 0e")
        let result = try XCTUnwrap(ScalePacketParser.parse(data))
        XCTAssertEqual(result.weightKg, 69.6, accuracy: 0.001)
        XCTAssertTrue(result.isStable)
        XCTAssertTrue(result.isFinal)
        XCTAssertEqual(result.impedance?.a, 482)
        XCTAssertEqual(result.impedance?.b, 432)
    }

    func testParsesFinalResultPacketWithoutImpedance() throws {
        let data = Data(hex: "ac 29 02 00 00 00 00 00 01 80 68 13 ec 00 00 00 00 29 d6 09")
        let result = try XCTUnwrap(ScalePacketParser.parse(data))
        XCTAssertEqual(result.weightKg, 5.1, accuracy: 0.001)
        XCTAssertTrue(result.isStable)
        XCTAssertTrue(result.isFinal)
        XCTAssertNil(result.impedance)
    }

    func testIgnoresInvalidPacket() {
        XCTAssertNil(ScalePacketParser.parse(Data([0x00, 0x01])))
    }
}

private extension Data {
    init(hex: String) {
        self.init(hex.split(separator: " ").map { UInt8($0, radix: 16)! })
    }
}
