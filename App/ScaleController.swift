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
    /// 改走快捷指令写入：用户主动选择，或免费证书剥掉 HealthKit entitlement 导致授权/写入失败。
    @Published var usesShortcut = UserDefaults.standard.bool(forKey: "AFUScale.usesShortcut") {
        didSet { UserDefaults.standard.set(usesShortcut, forKey: "AFUScale.usesShortcut") }
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
            if let latest {
                let m = metrics(latest)
                lastSavedText = String(format: "已写入：%.2f kg / BMI %.1f / 体脂 %.1f%%", m.weight, m.bmi, m.fat)
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

    /// 当前测量值对应的快捷指令链接；没测过则为 nil。
    var shortcutURL: URL? {
        guard let latest else { return nil }
        let m = metrics(latest)
        return Self.shortcutURL(weight: m.weight, bmi: m.bmi, fat: m.fat)
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
        needsHealthAuthorization = !health.isWriteAuthorized
        loadRecords()
        central = CBCentralManager(
            delegate: self,
            queue: nil,
            options: [CBCentralManagerOptionRestoreIdentifierKey: "AFUScale.central"]
        )
    }

    func requestHealthAuthorization() {
        if health.isWriteAuthorized {
            needsHealthAuthorization = false
            usesShortcut = false
            status = "Health 已授权，等待秤"
            loadRecords()
            startScanningIfReady()
            return
        }
        Task {
            do {
                try await health.requestAuthorization()
                needsHealthAuthorization = !health.isWriteAuthorized
                usesShortcut = false
                status = health.isWriteAuthorized ? "Health 已授权，等待秤" : "Health 未授权写入"
                loadRecords()
                startScanningIfReady()
            } catch {
                usesShortcut = true
                status = "Health 授权失败：\(error.localizedDescription)"
            }
        }
    }

    func loadRecords() {
        Task {
            if let list = try? await health.fetchRecords() {
                records = list
            }
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
                usesShortcut = true
                lastSavedText = String(format: "待写入：%.2f kg / BMI %.1f / 体脂 %.1f%%", weight, bmi, fat)
                status = "写入 Health 失败：\(error.localizedDescription)"
                disconnectFromScale()
            }
        }
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
        Task {
            for record in targets {
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
