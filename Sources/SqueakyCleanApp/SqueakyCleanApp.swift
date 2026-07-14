import SwiftUI

@main
struct SqueakyCleanApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup("SqueakyClean") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 1100, minHeight: 720)
        }
        .defaultSize(width: 1200, height: 760)
    }
}
