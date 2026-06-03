import AppKit
import Combine
import SwiftUI
import WizKit

/// Application delegate: owns the status item, the controller window, and the
/// menu-bar lifecycle. Mirrors blue-switch's AppDelegate — the LSUIElement +
/// `.accessory` activation-policy dance, the manual window, and the quit
/// semantics that keep the app living in the menu bar.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  // MARK: - State

  /// The single shared app state. The status item, menu, and views all read it.
  let appState = AppState()

  private var statusItem: NSStatusItem!
  private var menuController: MenuBarController!
  /// Cached controller window. Built lazily on first open, kept across closes.
  private var windowController: ControllerWindowController?

  private var observers: Set<AnyCancellable> = []
  private var windowCloseObserver: NSObjectProtocol?

  /// Set true by `quitFromStatusBar` just before `terminate`, so
  /// `applicationShouldTerminate` knows this is a real exit (not Cmd+Q in the
  /// window, which should just close the window and keep us in the menu bar).
  private var quitFromStatusBarMenu = false

  // MARK: - Lifecycle

  func applicationDidFinishLaunching(_ notification: Notification) {
    menuController = MenuBarController(appState: appState, delegate: self)
    setupStatusBar()
    setupActivationPolicyTracking()
    observeState()

    // Best-effort, silent, throttled to once per 24h. Drives the "Update
    // Available" item in the menu.
    UpdateChecker.shared.checkIfNeeded()

    // A restored light (if any) already started connecting in
    // AppState.init → selectLight → sync.
  }

  /// Dock-icon click. The Dock entry only exists while the controller window is
  /// open (we're `.accessory` otherwise), so reopen the window if none is visible.
  func applicationShouldHandleReopen(
    _ sender: NSApplication, hasVisibleWindows flag: Bool
  ) -> Bool {
    if !flag {
      openController(tab: .controls)
      return false
    }
    return true
  }

  /// Quit semantics: real exit only for the status-bar Quit or a system
  /// logout/shutdown. Otherwise (Cmd+Q in the window, Dock → Quit) just close
  /// the window and drop back to `.accessory` — stay in the menu bar.
  func applicationShouldTerminate(
    _ sender: NSApplication
  ) -> NSApplication.TerminateReply {
    if quitFromStatusBarMenu { return .terminateNow }
    if Self.isSystemInitiatedQuit() { return .terminateNow }
    for window in NSApp.windows where window.isVisible && window.level == .normal {
      window.close()
    }
    NSApp.setActivationPolicy(.accessory)
    return .terminateCancel
  }

  /// True when the current AppleEvent is logout / shutdown / restart — without
  /// this we'd hang the system during shutdown by cancelling the terminate.
  private static func isSystemInitiatedQuit() -> Bool {
    guard let event = NSAppleEventManager.shared().currentAppleEvent,
      let reason = event.attributeDescriptor(forKeyword: AEKeyword(kAEQuitReason))?
        .enumCodeValue
    else { return false }
    return reason == kAELogOut
      || reason == kAEReallyLogOut
      || reason == kAEShowRestartDialog
      || reason == kAEShowShutdownDialog
      || reason == kAERestart
      || reason == kAEShutDown
  }

  deinit {
    if let token = windowCloseObserver {
      NotificationCenter.default.removeObserver(token)
    }
  }

  // MARK: - Status bar

  private func setupStatusBar() {
    NSApp.setActivationPolicy(.accessory)
    statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    guard let button = statusItem.button else { return }
    button.target = self
    button.action = #selector(handleClick(_:))
    button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    refreshStatusIcon()
  }

  /// Re-render the status item icon + tooltip from current state. The icon is a
  /// filled bulb when on, an outline when off; template-rendered so it adapts to
  /// light/dark menu bars.
  private func refreshStatusIcon() {
    guard let button = statusItem?.button else { return }
    let on = appState.state.on && appState.connected
    let symbol = on ? "lightbulb.fill" : "lightbulb"
    let label = statusTooltip()
    let image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
    image?.isTemplate = true
    button.image = image
    button.toolTip = label
    button.setAccessibilityLabel(label)
  }

  private func statusTooltip() -> String {
    guard appState.hasLight else { return "WiZ Light Controller — No light selected" }
    let power = appState.connected ? (appState.state.on ? "On" : "Off") : "Unreachable"
    return "\(appState.displayName) — \(power)"
  }

  /// Observe app state so the status icon tracks power/connection changes.
  private func observeState() {
    appState.objectWillChange
      .receive(on: DispatchQueue.main)
      .sink { [weak self] in
        // objectWillChange fires *before* the mutation; hop a tick so we read
        // the new value.
        DispatchQueue.main.async { self?.refreshStatusIcon() }
      }
      .store(in: &observers)
  }

  // MARK: - Click → menu

  /// Both buttons open the menu. We attach the menu, synthesize a click to pop
  /// it, then detach — the standard status-item "click opens menu" trick that
  /// still lets us field plain clicks for other behaviours if needed.
  @objc private func handleClick(_ sender: NSStatusBarButton) {
    let menu = menuController.makeMenu()
    statusItem.menu = menu
    statusItem.button?.performClick(nil)
    statusItem.menu = nil
  }

  // MARK: - Menu actions (targets for MenuBarController items)

  @objc func togglePower(_ sender: NSMenuItem) {
    appState.setPower(!appState.state.on)
  }

  /// Select a saved light from the menu. `representedObject` carries its MAC.
  @objc func selectSavedLight(_ sender: NSMenuItem) {
    guard let mac = sender.representedObject as? String,
      let light = appState.savedLights[mac]
    else { return }
    if mac == appState.selectedMac, appState.connected {
      appState.disconnect()  // clicking the already-connected light disconnects it
    } else {
      appState.selectLight(name: light.name, ip: light.ip, mac: mac)
    }
  }

  @objc func openControllerFromMenu(_ sender: Any?) {
    openController(tab: .controls)
  }

  @objc func openLatestReleasePage(_ sender: Any?) {
    guard let url = UpdateChecker.shared.releasePageURL else { return }
    NSWorkspace.shared.open(url)
  }

  /// Status-bar Quit: set the flag so `applicationShouldTerminate` lets us exit.
  @objc func quitFromStatusBar(_ sender: Any?) {
    quitFromStatusBarMenu = true
    NSApp.terminate(sender)
  }

  // MARK: - Window

  /// Open (and build, first time) the controller window. Bump to `.regular` so
  /// it gets a Dock icon + can become key (tooltips need a key window under
  /// `.regular`).
  private func openController(tab: ControllerWindowController.Tab) {
    NSApp.setActivationPolicy(.regular)
    NSApp.activate(ignoringOtherApps: true)
    if windowController == nil {
      windowController = ControllerWindowController(appState: appState)
    }
    windowController?.show(tab: tab)
  }

  /// Drop back to `.accessory` (no Dock icon) once the last normal window closes.
  private func setupActivationPolicyTracking() {
    windowCloseObserver = NotificationCenter.default.addObserver(
      forName: NSWindow.willCloseNotification, object: nil, queue: .main
    ) { [weak self] notification in
      guard let window = notification.object as? NSWindow, window.level == .normal else { return }
      // willClose fires while the window is still flagged visible; defer a tick
      // so the count reflects the post-close state.
      DispatchQueue.main.async {
        guard self != nil else { return }
        let open = NSApp.windows.filter { $0.isVisible && $0.level == .normal }
        if open.isEmpty { NSApp.setActivationPolicy(.accessory) }
      }
    }
  }
}
