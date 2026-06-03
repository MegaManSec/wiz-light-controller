import AppKit
import SwiftUI

/// Hosts `ControllerView` in a manually-built, cached `NSWindow`. We don't use a
/// SwiftUI `WindowGroup`/`Settings` scene because under `LSUIElement` +
/// `.accessory` those don't reliably produce a visible window (see blue-switch's
/// AppDelegate notes). The window is kept alive across closes
/// (`isReleasedWhenClosed = false`) so reopening is just `makeKeyAndOrderFront`.
@MainActor
final class ControllerWindowController: NSWindowController {
  private let appState: AppState

  /// Which tab the controller should show when next opened.
  enum Tab { case controls, settings }

  init(appState: AppState) {
    self.appState = appState
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 620, height: 760),
      styleMask: [.titled, .closable, .miniaturizable],
      backing: .buffered,
      defer: false
    )
    window.title = "WiZ Light Controller"
    window.isReleasedWhenClosed = false
    window.center()
    window.contentMinSize = NSSize(width: 620, height: 520)
    // Open on whichever Space the user is currently viewing, instead of yanking
    // them to the desktop where the window was first created.
    window.collectionBehavior.insert(.moveToActiveSpace)
    // Also let it float over a full-screen app instead of opening on a hidden desktop.
    window.collectionBehavior.insert(.fullScreenAuxiliary)
    super.init(window: window)
    window.contentView = NSHostingView(rootView: ControllerView().environmentObject(appState))
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  /// Bring the window to the front, selecting `tab`.
  func show(tab: Tab = .controls) {
    appState.selectedTab = tab
    showWindow(nil)
    window?.makeKeyAndOrderFront(nil)
  }
}
