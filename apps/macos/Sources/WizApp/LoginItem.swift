import Foundation
import ServiceManagement

/// Launch-at-login for the app itself, via `SMAppService.mainApp` (macOS 13+).
///
/// Used so the "restore on startup" power option can bring the light back after a
/// full shutdown: the app must be running again at boot to send the turn-on, so it
/// registers itself as a login item. `SMAppService.mainApp` registers the *main
/// bundle* (no embedded helper, works under the App Sandbox), and because the app
/// is `LSUIElement` a login launch just brings up the menu-bar item — no window.
///
/// Note: registration needs a properly signed build to take effect; under the
/// ad-hoc signing used for local dev it may silently fail to register.
enum LoginItem {
  /// Whether the app is currently registered to open at login.
  static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

  /// Register / unregister the app as a login item. No-ops when already in the
  /// desired state; failures are logged, not surfaced — the Settings toggle stays
  /// optimistic and re-syncs from `isEnabled` on the next launch.
  static func setEnabled(_ enabled: Bool) {
    do {
      if enabled {
        if SMAppService.mainApp.status != .enabled { try SMAppService.mainApp.register() }
      } else {
        if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
      }
    } catch {
      NSLog("LoginItem.setEnabled(\(enabled)) failed: \(error.localizedDescription)")
    }
  }
}
