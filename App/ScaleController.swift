import CoreBluetooth
import Foundation

@MainActor
final class ScaleController: NSObject, ObservableObject {
    @Published var status = "初始化"
    @Published var latest: ScaleMeasurement?
    @Published var latestRawHex = ""
    @Published var lastSavedText = "尚未写入"
    @Published var needsHealthAuthorization = false
    @Published var records: [SavedRecord] = []
    /// 改走快捷指令写入：用户主动选择，或 Health 不可写时自动落到这里。
    @Published var usesShortcut = UserDefaults.standard.bool(forKey: "AFUScale.usesShortcut") {
        didSet { UserDefaults.standard.set(usesShortcut, forKey: "AFUScale.usesShortcut") }
    }
    /// 签名不含 HealthKit entitlement（免费证书侧载）：授权必然报错，锁死在快捷指令，不允许切回。
    @Published var healthUnavailable = UserDefaults.standard.bool(forKey: "AFUScale.healthUnavailable") {
        didSet { UserDefaults.standard.set(healthUnavailable, forKey: "AFUScale.healthUnavailable") }
    }
    /// 已交给快捷指令、等回跳确认的那一条。
    @Published private var pendingRecord: LocalRecord?

    enum WriteTarget: Hashable { case health, shortcut }

    /// 给切换控件用：切到 Health 要先过授权校验，没过就维持快捷指令（控件自动回弹）。
    var writeTarget: WriteTarget {
        get { usesShortcut ? .shortcut : .health }
        set {
            switch newValue {
            case .shortcut: useShortcut()
            case .health: requestHealthAuthorization()
            }
        }
    }

    // ponytail: 快捷指令名写死，用户按这个名字建捷径即可；要改名再加设置项。
    static let shortcutName = "AFUScale 写入健康"
    /// 快捷指令跑完通过 x-callback-url 跳回本 App 用的 scheme（同步登记在 Info.plist）。
    static let callbackScheme = "afuscale"

    /// 交给「快捷指令」的文本输入为 JSON，捷径里用「从输入获取词典」取值。
    /// fat 是百分数本身（18.70 即 18.70%），快捷指令里直接填入，不要再乘除 100。
    static func shortcutURL(name: String = shortcutName, weight: Double, bmi: Double, fat: Double) -> URL? {
        var components = URLComponents(string: "shortcuts://x-callback-url/run-shortcut")
        components?.queryItems = [
            URLQueryItem(name: "name", value: name),
            URLQueryItem(name: "input", value: "text"),
            URLQueryItem(name: "text", value: String(format: "{\"weight\":%.2f,\"bmi\":%.2f,\"fat\":%.2f}", weight, bmi, fat)),
            URLQueryItem(name: "x-success", value: "\(callbackScheme)://saved"),
            URLQueryItem(name: "x-error", value: "\(callbackScheme)://failed"),
            URLQueryItem(name: "x-cancel", value: "\(callbackScheme)://cancelled")
        ]
        return components?.url
    }

    /// 处理快捷指令跑完后回跳的 x-callback-url。
    func handleCallback(_ url: URL) {
        guard url.scheme == Self.callbackScheme else { return }
        switch url.host {
        case "saved":
            // 快捷指令写 Health 的结果读不回来，回跳即视为成功，本地存一份用于展示。
            if let pendingRecord {
                localRecords.append(pendingRecord)
                lastSavedText = String(format: "已写入：%.2f kg / BMI %.1f / 体脂 %.1f%%", pendingRecord.weightKg, pendingRecord.bmi, pendingRecord.bodyFatPercent)
                self.pendingRecord = nil
                loadRecords()
            }
            status = "快捷指令写入完成"
        case "cancelled":
            status = "快捷指令已取消"
        default:
            let message = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "errorMessage" }?.value
            status = "快捷指令写入失败：\(message ?? "未知错误")"
        }
    }

    /// 待写入那条对应的快捷指令链接；没测过则为 nil。
    var shortcutURL: URL? {
        guard let pendingRecord else { return nil }
        return Self.shortcutURL(weight: pendingRecord.weightKg, bmi: pendingRecord.bmi, fat: pendingRecord.bodyFatPercent)
    }

    /// 快捷指令写入的记录 Health 里读不到，存在本地。
    private struct LocalRecord: Codable {
        let date: Date
        let weightKg: Double
        let bmi: Double
        let bodyFatPercent: Double
    }

    private static let localRecordsKey = "AFUScale.shortcutRecords"
    private var localRecords: [LocalRecord] = [] {
        didSet { UserDefaults.standard.set(try? JSONEncoder().encode(localRecords), forKey: Self.localRecordsKey) }
    }

    private let health = HealthWriter()
    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var lastSavedAt: Date?

    private let targetName = "AFU-WL-TZ-A1"
    private let ffb0 = CBUUID(string: "0000FFB0-0000-1000-8000-00805F9B34FB")
    private let ffb2 = CBUUID(string: "0000FFB2-0000-1000-8000-00805F9B34FB")

    // 身高/年龄在页面配置，持久化到 UserDefaults；性别/校正值仍写死。
    @Published var heightCm: Double { didSet { UserDefaults.standard.set(heightCm, forKey: "AFUScale.heightCm") } }
    @Published var age: Int { didSet { UserDefaults.standard.set(age, forKey: "AFUScale.age") } }
    private let sex: Sex = .male
    private let calibration = 1.5

    override init() {
        let d = UserDefaults.standard
        heightCm = d.object(forKey: "AFUScale.heightCm") as? Double ?? 170.0
        age = d.object(forKey: "AFUScale.age") as? Int ?? 25
        super.init()
        localRecords = d.data(forKey: Self.localRecordsKey)
            .flatMap { try? JSONDecoder().decode([LocalRecord].self, from: $0) } ?? []
        needsHealthAuthorization = !health.isWriteAuthorized
        loadRecords()
        central = CBCentralManager(
            delegate: self,
            queue: nil,
            options: [CBCentralManagerOptionRestoreIdentifierKey: "AFUScale.central"]
        )
    }

    /// 改用快捷指令写入。
    func useShortcut() {
        usesShortcut = true
        if pendingRecord == nil, let latest {
            pendingRecord = record(latest)
        }
        status = "使用快捷指令写入"
    }

    /// 锁定是持久的，换成带 HealthKit 权限的签名后靠这个解锁重试。
    func retryHealth() {
        healthUnavailable = false
        requestHealthAuthorization()
    }

    /// 切回 Apple 健康：只有拿到写入权限才真的切，否则维持快捷指令。
    func requestHealthAuthorization() {
        guard !healthUnavailable else { return }
        if health.isWriteAuthorized {
            healthAuthorized()
            return
        }
        Task {
            do {
                try await health.requestAuthorization()
                if health.isWriteAuthorized {
                    healthAuthorized()
                } else {
                    needsHealthAuthorization = true
                    status = usesShortcut ? "未获得健康写入权限，继续用快捷指令" : "Health 未授权写入"
                }
            } catch {
                // entitlement 被剥掉时必然走这里，不再拿授权错误刷状态栏。
                healthUnavailable = true
                useShortcut()
            }
        }
    }

    private func healthAuthorized() {
        needsHealthAuthorization = false
        healthUnavailable = false
        usesShortcut = false
        status = "Health 已授权，等待秤"
        loadRecords()
        startScanningIfReady()
    }

    func loadRecords() {
        Task {
            let fromHealth = (try? await health.fetchRecords()) ?? []
            let fromShortcut = localRecords.map {
                SavedRecord(date: $0.date, weightKg: $0.weightKg, bmi: $0.bmi, bodyFatPercent: $0.bodyFatPercent, samples: [])
            }
            records = (fromHealth + fromShortcut).sorted { $0.date > $1.date }
        }
    }

    private func startScanningIfReady() {
        guard central.state == .poweredOn else { return }
        status = "等待秤"
        // 前台调试用 nil 扫描所有设备，避免 iOS 因广告包服务字段差异漏掉设备。
        // 连接时再按名称/FFB0 过滤。后台唤醒稳定后可改回 [ffb0]。
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
    }

    private func handle(_ measurement: ScaleMeasurement, rawHex: String) {
        latest = measurement
        latestRawHex = rawHex
        print("[AFUScale][parsed] weight=\(measurement.weightKg) stable=\(measurement.isStable) final=\(measurement.isFinal) impedance=\(String(describing: measurement.impedance))")
        // 只写最终结果包（byte[2] == 0x02）。阻抗可能为 0，体重仍有效。
        guard measurement.isFinal else {
            print("[AFUScale][skip] not final result packet")
            return
        }
        print("[AFUScale][save] final result packet")
        save(measurement)
    }

    private func save(_ measurement: ScaleMeasurement) {
        if let lastSavedAt, Date().timeIntervalSince(lastSavedAt) < 90 {
            disconnectFromScale()
            return
        }
        lastSavedAt = Date()

        let (weight, bmi, fat) = metrics(measurement)
        guard !usesShortcut else {
            pendingRecord = record(measurement)
            lastSavedText = String(format: "待写入：%.2f kg / BMI %.1f / 体脂 %.1f%%", weight, bmi, fat)
            status = "等待通过快捷指令写入"
            disconnectFromScale()
            return
        }
        Task {
            do {
                try await health.save(weightKg: weight, bmi: bmi, bodyFatPercent: fat)
                loadRecords()
                lastSavedText = String(format: "已写入：%.2f kg / BMI %.1f / 体脂 %.1f%%", weight, bmi, fat)
                status = "写入完成，断开连接"
                disconnectFromScale()
            } catch {
                pendingRecord = record(measurement)
                usesShortcut = true
                lastSavedText = String(format: "待写入：%.2f kg / BMI %.1f / 体脂 %.1f%%", weight, bmi, fat)
                status = "Health 写入失败，改用快捷指令"
                disconnectFromScale()
            }
        }
    }

    private func record(_ measurement: ScaleMeasurement, date: Date = Date()) -> LocalRecord {
        let m = metrics(measurement)
        return LocalRecord(date: date, weightKg: m.weight, bmi: m.bmi, bodyFatPercent: m.fat)
    }

    private func metrics(_ measurement: ScaleMeasurement) -> (weight: Double, bmi: Double, fat: Double) {
        let weight = (measurement.weightKg * 100).rounded() / 100
        return (
            weight,
            BodyMetrics.bmi(weightKg: weight, heightCm: heightCm),
            BodyMetrics.bodyFatPercent(weightKg: weight, heightCm: heightCm, age: age, sex: sex, calibration: calibration)
        )
    }

    func deleteRecords(at offsets: IndexSet) {
        let targets = offsets.map { records[$0] }
        records.remove(atOffsets: offsets)
        // 没有 sample 的就是快捷指令写的本地记录，按时间戳删。
        let localDates = Set(targets.filter { $0.samples.isEmpty }.map(\.date))
        localRecords.removeAll { localDates.contains($0.date) }
        Task {
            for record in targets where !record.samples.isEmpty {
                try? await health.delete(record.samples)
            }
            loadRecords()
        }
    }

    private func disconnectFromScale() {
        guard let peripheral else {
            startScanningIfReady()
            return
        }
        central.cancelPeripheralConnection(peripheral)
    }
}

extension ScaleController: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        Task { @MainActor in
            if central.state == .poweredOn {
                self.startScanningIfReady()
            } else {
                self.status = "蓝牙不可用：\(central.state.rawValue)"
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, willRestoreState dict: [String : Any]) {
        Task { @MainActor in
            self.status = "系统恢复后台蓝牙状态"
            self.startScanningIfReady()
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String : Any], rssi RSSI: NSNumber) {
        let localName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let peripheralName = peripheral.name
        let nameForDisplay = localName ?? peripheralName ?? ""
        let serviceUUIDs = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID]) ?? []
        Task { @MainActor in
            let hasFFB0 = serviceUUIDs.contains(self.ffb0)
            let isTargetLocalName = localName == self.targetName
            let isClone = nameForDisplay.contains("Clone")
            guard (isTargetLocalName || hasFFB0), !isClone else { return }
            self.status = "发现 AFU-WL-TZ-A1，连接中"
            self.peripheral = peripheral
            peripheral.delegate = self
            central.stopScan()
            central.connect(peripheral, options: nil)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        Task { @MainActor in
            self.status = "已连接，发现服务"
            peripheral.discoverServices([self.ffb0])
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        Task { @MainActor in
            self.peripheral = nil
            self.status = "已断开，等待秤"
            self.startScanningIfReady()
        }
    }
}

extension ScaleController: CBPeripheralDelegate {
    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        Task { @MainActor in
            guard let services = peripheral.services else { return }
            for service in services where service.uuid == self.ffb0 {
                peripheral.discoverCharacteristics([self.ffb2], for: service)
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        Task { @MainActor in
            guard let chars = service.characteristics else { return }
            for ch in chars where ch.uuid == self.ffb2 {
                self.status = "订阅称重数据"
                peripheral.setNotifyValue(true, for: ch)
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid == CBUUID(string: "0000FFB2-0000-1000-8000-00805F9B34FB"),
              let data = characteristic.value else { return }
        let rawHex = data.map { String(format: "%02x", $0) }.joined(separator: " ")
        print("[AFUScale][raw] \(rawHex)")
        guard let measurement = ScalePacketParser.parse(data) else {
            print("[AFUScale][skip] parse failed")
            return
        }
        Task { @MainActor in
            self.handle(measurement, rawHex: rawHex)
        }
    }
}
