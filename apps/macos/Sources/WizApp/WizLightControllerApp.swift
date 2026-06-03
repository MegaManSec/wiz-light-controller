import SwiftUI

/// Application entry point. The real UI is a menu-bar status item plus a manual
/// `NSWindow` for the controller — both wired up in `AppDelegate`.
@main
struct WizLightControllerApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

  /// This `Settings` scene exists only because `App.body` requires at least one
  /// `Scene`. It is intentionally unreachable: under `LSUIElement` + `.accessory`
  /// the SwiftUI `Settings { … }` + `showSettingsWindow:` path silently fails to
  /// produce a visible window, so `AppDelegate` hosts the controller window
  /// manually instead. Mirrors blue-switch.
  var body: some Scene {
    Settings { EmptyView() }
  }
}
