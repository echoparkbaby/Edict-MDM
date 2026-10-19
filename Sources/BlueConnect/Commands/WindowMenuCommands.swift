import SwiftUI

/// Adds a "Show BlueConnect Admin" item to the Window menu (⌘0) so the
/// main window can be brought back after the user closes it via the red
/// traffic light. Without this, the only way back is to relaunch the
/// app — since `MainWindowCloseGuard` swallows ⌘W on the main window,
/// a close requires the red light, which gives no obvious path to
/// reopen.
struct WindowMenuCommands: Commands {
    var body: some Commands {
        CommandGroup(after: .windowList) {
            Divider()
            Button("Show BlueConnect Admin") {
                // A CommandGroup has no containing view (and so no
                // openWindow env value); the reopener fronts the existing
                // main window or falls back to its captured openWindow.
                MainWindowReopener.shared.reopen()
            }
            .keyboardShortcut("0", modifiers: [.command])
        }
    }
}

/// Brings the main window back. Holds the SwiftUI `openWindow` action
/// captured by `MainWindowReopenerCapture` on the main WindowGroup's
/// `.onAppear`, used only when no main window is left to front.
@MainActor
final class MainWindowReopener {
    static let shared = MainWindowReopener()
    var open: (() -> Void)?

    /// Fronts the existing main window; only opens a new one when none is
    /// left. `openWindow(id: "main")` on a WindowGroup always adds another
    /// window, so callers must come through here.
    func reopen() {
        NSApp.activate()
        if let w = NSApp.windows.first(where: { $0.isBlueConnectAdminMainWindow && ($0.isVisible || $0.isMiniaturized) }) {
            w.makeKeyAndOrderFront(nil)
        } else {
            open?()
        }
    }
}

/// Tiny view-modifier that captures `openWindow` once and hands it to
/// `MainWindowReopener` so the menu command can reach it from outside
/// the view hierarchy.
struct MainWindowReopenerCapture: ViewModifier {
    @Environment(\.openWindow) private var openWindow
    func body(content: Content) -> some View {
        content.onAppear {
            MainWindowReopener.shared.open = {
                openWindow(id: "main")
            }
        }
    }
}
