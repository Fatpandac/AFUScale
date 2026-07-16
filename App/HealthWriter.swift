import Foundation
import HealthKit

struct SavedRecord: Identifiable {
    let id = UUID()
    let date: Date
    let weightKg: Double
    let bmi: Double
    let bodyFatPercent: Double
    let samples: [HKQuantitySample]
}

final class HealthWriter {
    private let store = HKHealthStore()

    private let bodyMass = HKQuantityType.quantityType(forIdentifier: .bodyMass)!
    private let bmiType = HKQuantityType.quantityType(forIdentifier: .bodyMassIndex)!
    private let bodyFat = HKQuantityType.quantityType(forIdentifier: .bodyFatPercentage)!

    var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    var isWriteAuthorized: Bool {
        guard isAvailable else { return true }
        return [bodyMass, bmiType, bodyFat].allSatisfy {
            store.authorizationStatus(for: $0) == .sharingAuthorized
        }
    }

    func requestAuthorization() async throws {
        guard isAvailable else { return }
        let types: Set = [bodyMass, bmiType, bodyFat]
        try await store.requestAuthorization(toShare: types, read: types)
    }

    @discardableResult
    func save(weightKg: Double, bmi: Double, bodyFatPercent: Double, date: Date = Date()) async throws -> [HKQuantitySample] {
        guard isAvailable else { return [] }
        let samples: [HKQuantitySample] = [
            HKQuantitySample(
                type: bodyMass,
                quantity: HKQuantity(unit: .gramUnit(with: .kilo), doubleValue: weightKg),
                start: date,
                end: date
            ),
            HKQuantitySample(
                type: bmiType,
                quantity: HKQuantity(unit: .count(), doubleValue: bmi),
                start: date,
                end: date
            ),
            HKQuantitySample(
                type: bodyFat,
                quantity: HKQuantity(unit: .percent(), doubleValue: bodyFatPercent / 100),
                start: date,
                end: date
            )
        ]
        try await store.save(samples)
        return samples
    }

    func delete(_ samples: [HKQuantitySample]) async throws {
        guard isAvailable, !samples.isEmpty else { return }
        try await store.delete(samples)
    }

    /// 从 HealthKit 读回本 App 写入的历史记录（持久化以 Health 为准）。
    func fetchRecords() async throws -> [SavedRecord] {
        guard isAvailable else { return [] }
        let predicate = HKQuery.predicateForObjects(from: .default())
        async let masses = samples(bodyMass, predicate)
        async let bmis = samples(bmiType, predicate)
        async let fats = samples(bodyFat, predicate)
        let (m, b, f) = try await (masses, bmis, fats)

        // 三种样本写入时共用同一时间戳，按秒对齐分组。
        func key(_ d: Date) -> Int { Int(d.timeIntervalSinceReferenceDate.rounded()) }
        let bmiByKey = Dictionary(b.map { (key($0.startDate), $0) }, uniquingKeysWith: { a, _ in a })
        let fatByKey = Dictionary(f.map { (key($0.startDate), $0) }, uniquingKeysWith: { a, _ in a })

        return m.map { mass -> SavedRecord in
            let k = key(mass.startDate)
            let bmiSample = bmiByKey[k]
            let fatSample = fatByKey[k]
            return SavedRecord(
                date: mass.startDate,
                weightKg: mass.quantity.doubleValue(for: .gramUnit(with: .kilo)),
                bmi: bmiSample?.quantity.doubleValue(for: .count()) ?? 0,
                bodyFatPercent: (fatSample?.quantity.doubleValue(for: .percent()) ?? 0) * 100,
                samples: [mass] + [bmiSample, fatSample].compactMap { $0 }
            )
        }
        .sorted { $0.date > $1.date }
    }

    private func samples(_ type: HKQuantityType, _ predicate: NSPredicate) async throws -> [HKQuantitySample] {
        try await withCheckedThrowingContinuation { cont in
            let q = HKSampleQuery(
                sampleType: type,
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: nil
            ) { _, result, error in
                if let error {
                    cont.resume(throwing: error)
                } else {
                    cont.resume(returning: (result as? [HKQuantitySample]) ?? [])
                }
            }
            store.execute(q)
        }
    }
}
