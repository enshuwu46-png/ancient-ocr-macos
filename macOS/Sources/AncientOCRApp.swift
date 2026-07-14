import SwiftUI

@main
struct AncientOCRApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1080, height: 720)
        .commands {
            CommandGroup(replacing: .newItem) { }
        }
    }
}

