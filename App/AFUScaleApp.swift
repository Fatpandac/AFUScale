import SwiftUI

@main
struct AFUScaleApp: App {
    @StateObject private var scale = ScaleController()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(scale)
                .onAppear {
                    scale.requestHealthAuthorization()
                }
        }
    }
}
