import SwiftUI
import AppKit

struct LauncherApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup("Launcher") {
            ContentView()
                .frame(width: 640, height: 420)
                .background(WindowAccessor { window in
                    delegate.mainWindow = window
                    configureWindow(window)
                })
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultSize(width: 640, height: 420)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }

    private func configureWindow(_ window: NSWindow) {
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.standardWindowButton(.closeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = true
        window.level = .normal
        window.styleMask.insert(.fullSizeContentView)
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        centerOnActiveScreen(window)
    }

    /// Center window on the screen containing the mouse cursor (multi-monitor setups).
    /// Falls back to main screen if mouse is off-screen.
    private func centerOnActiveScreen(_ window: NSWindow) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSPointInRect(mouse, $0.frame) }
            ?? NSScreen.main
            ?? NSScreen.screens.first
        guard let s = screen else { return window.center() }
        let frame = s.visibleFrame
        let w = window.frame.size.width
        let h = window.frame.size.height
        let x = frame.origin.x + (frame.size.width - w) / 2
        // Place slightly above center (Spotlight convention).
        let y = frame.origin.y + (frame.size.height - h) / 2 + frame.size.height * 0.1
        window.setFrameOrigin(NSPoint(x: x, y: y))
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var mainWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        AppIndex.shared.loadCachedThenRefresh()
        // Observe key changes ONLY on our main window — not arbitrary system panels.
        NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self, let w = note.object as? NSWindow, w === self.mainWindow else { return }
            NotificationCenter.default.post(name: .launcherShouldFocus, object: nil)
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showAndFocus()
        return true
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        showAndFocus()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    private func showAndFocus() {
        guard let w = mainWindow else { return }
        // Re-center on active screen (mouse may have moved to a different display).
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSPointInRect(mouse, $0.frame) } ?? NSScreen.main
        if let s = screen {
            let frame = s.visibleFrame
            let size = w.frame.size
            let x = frame.origin.x + (frame.size.width - size.width) / 2
            let y = frame.origin.y + (frame.size.height - size.height) / 2 + frame.size.height * 0.1
            w.setFrameOrigin(NSPoint(x: x, y: y))
        }
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        NotificationCenter.default.post(name: .launcherShouldFocus, object: nil)
    }
}

extension Notification.Name {
    static let launcherShouldFocus = Notification.Name("LauncherShouldFocus")
}

struct WindowAccessor: NSViewRepresentable {
    let onWindow: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async {
            if let w = v.window { onWindow(w) }
        }
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            if let w = nsView.window { onWindow(w) }
        }
    }
}
