import SwiftUI

@main
struct AFUScaleApp: App {
    @StateObject private var scale = ScaleController()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(scale)
                .onAppear {
                    // 已选快捷指令写入就不再骚扰健康授权。
                    if !scale.usesShortcut {
                        scale.requestHealthAuthorization()
                    }
                }
                .onOpenURL { scale.handleCallback($0) }
        }
    }
}
