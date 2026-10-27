import AppKit
import ServiceManagement

@main
@MainActor
enum ClaudeIsland {
    static func main() {
        let store = SessionStore()
        let server = HookServer(store: store)
        server.start()

        store.sync(with: SessionRegistry.load())
        Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in
            MainActor.assumeIsolated { store.sync(with: SessionRegistry.load()) }
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { note in
            let id = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
            MainActor.assumeIsolated {
                // Clicking the island activates it: keep the previous app.
                if let id, id != Bundle.main.bundleIdentifier { store.frontmostApp = id }
            }
        }

        registerLoginItemOnce()
        NSApplication.shared.setActivationPolicy(.accessory)
        let panel = NotchPanel(store: store)
        panel.orderFrontRegardless()

        withExtendedLifetime((server, panel)) { NSApplication.shared.run() }
    }

    /// Opens at login from the first bundled launch; turning it off in System Settings sticks.
    private static func registerLoginItemOnce() {
        let key = "loginItemRegistered"
        guard Bundle.main.bundleIdentifier != nil, !UserDefaults.standard.bool(forKey: key) else { return }
        do {
            try SMAppService.mainApp.register()
            UserDefaults.standard.set(true, forKey: key)
        } catch {
            print("Login item: \(error)")
        }
    }
}
