import Foundation

enum Sex {
    case male
    case female
}

enum BodyMetrics {
    static func bmi(weightKg: Double, heightCm: Double) -> Double {
        let h = heightCm / 100
        return weightKg / (h * h)
    }

    static func bodyFatPercent(weightKg: Double, heightCm: Double, age: Int, sex: Sex, calibration: Double) -> Double {
        let sexValue = sex == .male ? 1.0 : 0.0
        return 1.20 * bmi(weightKg: weightKg, heightCm: heightCm)
            + 0.23 * Double(age)
            - 10.8 * sexValue
            - 5.4
            + calibration
    }
}
