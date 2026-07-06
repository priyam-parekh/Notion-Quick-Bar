import SwiftUI

@main
struct NotionMenuBarApp: App {
    @StateObject private var store = TaskStore()

    init() {
        MainActor.assumeIsolated {
            HotKeyManager.shared.register()
        }
    }

    var body: some Scene {
        MenuBarExtra {
            ContentView(removesWindowChrome: true)
                .environmentObject(store)
        } label: {
            Image(nsImage: MenuBarIcon.image(taskCount: store.todayTasks.count))
        }
        .menuBarExtraStyle(.window)
    }
}
