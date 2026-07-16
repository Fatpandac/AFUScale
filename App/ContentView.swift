import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var scale: ScaleController
    @FocusState private var focusedField: ProfileField?
    @State private var showsRawData = false

    private enum ProfileField {
        case height, age
    }

    private enum Palette {
        static let blue = Color(red: 0, green: 0.4, blue: 0.8)
        static let ink = Color(red: 29 / 255, green: 29 / 255, blue: 31 / 255)
        static let muted = Color(red: 122 / 255, green: 122 / 255, blue: 122 / 255)
        static let parchment = Color(red: 245 / 255, green: 245 / 255, blue: 247 / 255)
        static let dark = Color(red: 39 / 255, green: 39 / 255, blue: 41 / 255)
        static let hairline = Color(red: 224 / 255, green: 224 / 255, blue: 224 / 255)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 0) {
                    header
                    measurement
                    profile
                    history
                    diagnostics
                    footer
                }
            }
            .background(Palette.parchment)
            .foregroundStyle(Palette.ink)
            .scrollDismissesKeyboard(.interactively)
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("完成") { focusedField = nil }
                        .foregroundStyle(Palette.blue)
                        .fontWeight(.semibold)
                }
            }
        }
        .tint(Palette.blue)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("AFU 体脂秤")
                .font(.system(size: 34, weight: .semibold))
                .tracking(-0.37)

            HStack(spacing: 8) {
                Circle()
                    .fill(Palette.blue)
                    .frame(width: 8, height: 8)
                Text(scale.status)
                    .font(.system(size: 14))
                    .foregroundStyle(Palette.muted)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 24)
        .padding(.top, 24)
        .padding(.bottom, 32)
        .background(Palette.parchment)
    }

    private var measurement: some View {
        VStack(spacing: 24) {
            VStack(spacing: 4) {
                Text("当前体重")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.75))

                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(scale.latest.map { String(format: "%.2f", $0.weightKg) } ?? "— —")
                        .font(.system(size: 56, weight: .semibold))
                        .tracking(-0.28)
                    Text("kg")
                        .font(.system(size: 21, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.75))
                }
            }

            if let measurement = scale.latest {
                HStack(spacing: 24) {
                    Label(measurement.isStable ? "已稳定" : "测量中", systemImage: measurement.isStable ? "checkmark.circle.fill" : "waveform")
                    if let impedance = measurement.impedance {
                        Label("\(impedance.a) · \(impedance.b)", systemImage: "bolt.fill")
                    }
                }
                .font(.system(size: 14))
                .foregroundStyle(Color.white.opacity(0.75))
            } else {
                Text("站上体脂秤后，测量结果会显示在这里。")
                    .font(.system(size: 17))
                    .foregroundStyle(Color.white.opacity(0.75))
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
        .padding(.vertical, 48)
        .foregroundStyle(.white)
        .background(Palette.dark)
    }

    private var profile: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 8) {
                Text("个人参数")
                    .font(.system(size: 21, weight: .semibold))
                    .tracking(-0.23)
                Text("用于计算 BMI 与体脂率，修改后会自动保存。")
                    .font(.system(size: 14))
                    .foregroundStyle(Palette.muted)
            }

            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("身高")
                        .font(.system(size: 14, weight: .semibold))
                    HStack(spacing: 4) {
                        TextField("170", value: $scale.heightCm, format: .number.precision(.fractionLength(0...1)))
                            .keyboardType(.decimalPad)
                            .font(.system(size: 21, weight: .semibold))
                            .multilineTextAlignment(.trailing)
                            .focused($focusedField, equals: .height)
                            .accessibilityLabel("身高")
                        Text("cm")
                            .font(.system(size: 14))
                            .foregroundStyle(Palette.muted)
                    }
                    .padding(.horizontal, 16)
                    .frame(height: 52)
                    .background(.white)
                    .clipShape(Capsule())
                    .overlay(Capsule().stroke(focusedField == .height ? Palette.blue : Palette.hairline, lineWidth: focusedField == .height ? 2 : 1))
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("年龄")
                        .font(.system(size: 14, weight: .semibold))
                    HStack(spacing: 4) {
                        TextField("25", value: $scale.age, format: .number)
                            .keyboardType(.numberPad)
                            .font(.system(size: 21, weight: .semibold))
                            .multilineTextAlignment(.trailing)
                            .focused($focusedField, equals: .age)
                            .accessibilityLabel("年龄")
                        Text("岁")
                            .font(.system(size: 14))
                            .foregroundStyle(Palette.muted)
                    }
                    .padding(.horizontal, 16)
                    .frame(height: 52)
                    .background(.white)
                    .clipShape(Capsule())
                    .overlay(Capsule().stroke(focusedField == .age ? Palette.blue : Palette.hairline, lineWidth: focusedField == .age ? 2 : 1))
                }
            }

            HStack(spacing: 12) {
                Image(systemName: "heart.text.square")
                    .foregroundStyle(Palette.blue)
                    .frame(width: 24)
                Text(scale.lastSavedText)
                    .font(.system(size: 14))
                    .foregroundStyle(Palette.muted)
            }

            if scale.needsHealthAuthorization {
                Button {
                    scale.requestHealthAuthorization()
                } label: {
                    Text("允许写入 Apple 健康")
                        .font(.system(size: 17))
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)
                .background(Palette.blue)
                .clipShape(Capsule())
                .accessibilityHint("打开 Apple 健康授权请求")
            }
        }
        .padding(24)
        .background(Palette.parchment)
    }

    private var history: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("写入记录")
                .font(.system(size: 21, weight: .semibold))
                .tracking(-0.23)
                .padding(.bottom, 16)

            if scale.records.isEmpty {
                Text("还没有记录")
                    .font(.system(size: 17))
                    .foregroundStyle(Palette.muted)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 32)
            } else {
                ForEach(Array(scale.records.enumerated()), id: \.element.id) { index, record in
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(String(format: "%.2f kg", record.weightKg))
                                .font(.system(size: 17, weight: .semibold))
                            Text(String(format: "BMI %.1f  ·  体脂 %.1f%%", record.bmi, record.bodyFatPercent))
                                .font(.system(size: 14))
                                .foregroundStyle(Palette.muted)
                            Text(record.date.formatted(date: .abbreviated, time: .shortened))
                                .font(.system(size: 12))
                                .foregroundStyle(Palette.muted)
                        }

                        Spacer()

                        Button(role: .destructive) {
                            scale.deleteRecords(at: IndexSet(integer: index))
                        } label: {
                            Image(systemName: "trash")
                                .frame(width: 44, height: 44)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("删除这条记录")
                    }
                    .padding(.vertical, 12)

                    if index < scale.records.count - 1 {
                        Divider()
                    }
                }
            }
        }
        .padding(24)
        .background(.white)
    }

    @ViewBuilder
    private var diagnostics: some View {
        if !scale.latestRawHex.isEmpty {
            DisclosureGroup("原始测量数据", isExpanded: $showsRawData) {
                Text(scale.latestRawHex)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Palette.muted)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 12)
            }
            .font(.system(size: 14, weight: .semibold))
            .padding(24)
            .background(Palette.parchment)
        }
    }

    private var footer: some View {
        Text("首次使用请允许蓝牙与健康权限。之后 iOS 会在称重广播出现时通过蓝牙后台模式唤醒 App。")
            .font(.system(size: 12))
            .foregroundStyle(Palette.muted)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 24)
            .padding(.vertical, 32)
            .background(Palette.parchment)
    }
}
