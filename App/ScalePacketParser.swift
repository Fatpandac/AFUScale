import Foundation

struct Impedance: Equatable {
    let a: Int
    let b: Int
}

struct ScaleMeasurement: Equatable {
    let weightKg: Double
    let isStable: Bool
    let isFinal: Bool
    let impedance: Impedance?
}

enum ScalePacketParser {
    static func parse(_ data: Data) -> ScaleMeasurement? {
        let b = [UInt8](data)
        guard b.count >= 20, b[0] == 0xAC, b[1] == 0x29 else { return nil }
        let kind = b[2]
        if kind == 0x02 {
            let a = Int(b[4]) << 8 | Int(b[5])
            let c = Int(b[6]) << 8 | Int(b[7])
            return ScaleMeasurement(
                weightKg: decodeWeight(b[10], b[11], b[12]),
                isStable: true,
                isFinal: true,
                impedance: (a == 0 && c == 0) ? nil : Impedance(a: a, b: c)
            )
        }
        return ScaleMeasurement(
            weightKg: decodeWeight(b[3], b[4], b[5]),
            isStable: (kind & 0x80) != 0,
            isFinal: false,
            impedance: nil
        )
    }

    private static func decodeWeight(_ a: UInt8, _ b: UInt8, _ c: UInt8) -> Double {
        // 高字节是 65.536kg 翻页，低 16 位是克。
        Double(Int(a) - 0x68) * 65.536 + Double(Int(b) << 8 | Int(c)) / 1000
    }
}
