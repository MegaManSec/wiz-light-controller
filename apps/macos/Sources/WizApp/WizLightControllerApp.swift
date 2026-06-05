import SwiftUI

/// Application entry point. The real UI is a menu-bar status item plus a manual
/// `NSWindow` for the controller — both wired up in `AppDelegate`.
@main
struct WizLightControllerApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

  init() {
    // We're a menu-bar agent with no document/window worth persisting — the
    // controller window is rebuilt on demand by `AppDelegate`, never restored.
    // Turn off window restoration so macOS can't reopen a window on relaunch; on
    // macOS 26 the placeholder `Settings` scene below would otherwise be restored
    // as a blank "… Settings" window on launch. Set here in `App.init`, which
    // runs before AppKit's restoration pass.
    UserDefaults.standard.set(false, forKey: "NSQuitAlwaysKeepsWindows")
  }

  /// This `Settings` scene exists only because `App.body` requires at least one
  /// `Scene`. It is intentionally unreachable: under `LSUIElement` + `.accessory`
  /// the SwiftUI `Settings { … }` + `showSettingsWindow:` path silently fails to
  /// produce a visible window, so `AppDelegate` hosts the controller window
  /// manually instead. Mirrors blue-switch.
  var body: some Scene {
    Settings { EmptyView() }
  }
}
