import AppKit
import Combine
import WizKit

/// Application delegate: owns the status item, the controller window, and the
/// menu-bar lifecycle. Mirrors blue-switch's AppDelegate — the LSUIElement +
/// `.accessory` activation-policy dance, the manual window, and the quit
/// semantics that keep the app living in the menu bar.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
  // MARK: - State

  /// The single shared app state. The status item, menu, and views all read it.
  let appState = AppState()

  private var statusItem: NSStatusItem!
  /// The menu-bar dropdown, as a status-item `NSMenu` whose single item hosts an
  /// AppKit `DropdownContentView`. A *tracked menu* is the only thing that keeps
  /// the macOS menu bar revealed over a full-screen Space, and AppKit controls
  /// (unlike SwiftUI ones) track correctly inside it — matching BetterDisplay.
  private var dropdownMenu: NSMenu?
  /// The AppKit content view inside the menu item, kept so its size can be
  /// refreshed to the live content each time the menu opens.
  private var dropdownContentView: DropdownContentView?
  /// Cached controller window. Built lazily on first open, kept across closes.
  private var windowController: ControllerWindowController?

  private var observers: Set<AnyCancellable> = []
  private var windowCloseObserver: NSObjectProtocol?
  private var strayWindowObserver: NSObjectProtocol?

  /// Set true by `quitFromStatusBar` just before `terminate`, so
  /// `applicationShouldTerminate` knows this is a real exit (not Cmd+Q in the
  /// window, which should just close the window and keep us in the menu bar).
  private var quitFromStatusBarMenu = false

  // MARK: - Lifecycle

  func applicationDidFinishLaunching(_ notification: Notification) {
    // `.help` tooltips have a long default initial-hover delay; shorten it to ~2s.
    UserDefaults.standard.set(2000, forKey: "NSInitialToolTipDelay")
    setupStatusBar()
    setupActivationPolicyTracking()
    setupStrayWindowGuard()
    observeState()
    observePowerEvents()
    // Opt out of sudden termination so logout/shutdown routes through the quit
    // AppleEvent → applicationShouldTerminate (which `isSystemInitiatedQuit`
    // reads) rather than a SIGKILL, giving the shutdown power-off a chance to
    // run. Harmless when the feature's off — we return `.terminateNow` at once.
    ProcessInfo.processInfo.disableSuddenTermination()

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
    if Self.isSystemInitiatedQuit() {
      // Logout / restart / shutdown — turn the light off first if opted in.
      appState.powerOffForShutdown()
      return .terminateNow
    }
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

  // MARK: - System power events

  /// Turn the light off before the Mac sleeps (gated by `AppState`'s setting).
  /// Registered on `NSWorkspace`'s *own* notification center, which posts
  /// `willSleepNotification` on the main thread synchronously during the sleep
  /// transition — so this selector handler runs inline and the off datagrams
  /// egress while Wi-Fi is still up. (A block dispatched to a queue could race
  /// the actual sleep, and on macOS 13 there's no `MainActor.assumeIsolated` to
  /// bridge one back synchronously.) Shutdown is handled in
  /// `applicationShouldTerminate` instead — see `AppState.powerOffForShutdown`.
  private func observePowerEvents() {
    let center = NSWorkspace.shared.notificationCenter
    center.addObserver(
      self, selector: #selector(systemWillSleep),
      name: NSWorkspace.willSleepNotification, object: nil)
    // Wake is the mirror of sleep: bring the light back on if the user opted into
    // restore. Unlike the off (which must egress before Wi-Fi drops, hence the
    // synchronous handler), the on can be patient — `AppState` re-probes and turns
    // the light on once the bulb is reachable again.
    center.addObserver(
      self, selector: #selector(systemDidWake),
      name: NSWorkspace.didWakeNotification, object: nil)
  }

  @objc private func systemWillSleep(_ notification: Notification) {
    appState.powerOffForSleep()
  }

  @objc private func systemDidWake(_ notification: Notification) {
    appState.lightShouldRestoreOnWake()
  }

  deinit {
    if let token = windowCloseObserver {
      NotificationCenter.default.removeObserver(token)
    }
    if let token = strayWindowObserver {
      NotificationCenter.default.removeObserver(token)
    }
    NSWorkspace.shared.notificationCenter.removeObserver(self)
  }

  // MARK: - Stray-window guard

  /// `App.body` must declare at least one `Scene`, so `WizLightControllerApp`
  /// ships a placeholder `Settings { EmptyView() }` meant to be unreachable. On
  /// macOS 26 that scene's window surfaces on its own at launch (and again the
  /// first time the app activates), dropping the user into a blank "WiZ Light
  /// Controller Settings" window — and because that window lacks
  /// `.moveToActiveSpace`, activating the app over a full-screen Space yanks the
  /// user to it. (`NSQuitAlwaysKeepsWindows = false` only suppresses the
  /// *restored* copy, never this fresh-launch one.) Close it on sight.
  private func setupStrayWindowGuard() {
    strayWindowObserver = NotificationCenter.default.addObserver(
      forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main
    ) { [weak self] note in
      guard let window = note.object as? NSWindow else { return }
      DispatchQueue.main.async { self?.closeIfStray(window) }
    }
    // It may already be on screen at launch (and never re-become key), so also
    // sweep what's open over the first second.
    for delay in [0.0, 0.3, 0.7] {
      DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
        guard let self else { return }
        for window in NSApp.windows { self.closeIfStray(window) }
      }
    }
  }

  /// Close `window` if it's the stray placeholder-scene window: a titled,
  /// non-sheet, non-panel window that isn't our controller window. (The dropdown
  /// is an NSMenu, whose window isn't titled, so it's never matched here.
  /// NSPanels are excluded because system panels — NSColorPanel, NSAlert,
  /// open/save — are titled too, and this observer runs for the app's lifetime;
  /// the stray SwiftUI Settings window is a plain NSWindow.)
  private func closeIfStray(_ window: NSWindow) {
    guard window.styleMask.contains(.titled), !window.isSheet, !(window is NSPanel),
      window !== windowController?.window
    else { return }
    window.close()
  }

  /// Bring the app forward with the (deprecated) `activate(ignoringOtherApps:)`
  /// rather than the newer no-argument `activate()`: a menu-bar agent must be able
  /// to surface its controls window *over a full-screen app*, and the cooperative
  /// `activate()` refuses to take over another app's full-screen Space (the window
  /// can then open blank). The dropdown is an NSMenu and never calls this — a
  /// status-item menu opens without activating, and menu tracking keeps the bar.
  private func activateApp() {
    NSApp.activate(ignoringOtherApps: true)
  }

  // MARK: - Status bar

  private func setupStatusBar() {
    NSApp.setActivationPolicy(.accessory)
    statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    // A status-item menu (not a popover/panel): clicking the item opens it as a
    // tracked menu, which keeps the menu bar revealed in full-screen and highlights
    // the item — and never activates the app, so it can't retract the bar.
    dropdownMenu = makeDropdownMenu()
    statusItem.menu = dropdownMenu
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
    let state: String
    switch appState.status {
    case .connected: state = appState.state.on ? "On" : "Off"
    case .connecting: state = "Connecting…"
    case .error(let message): state = message
    case .disconnected, .noLight: state = "Unreachable"
    }
    return "\(appState.displayName) — \(state)"
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

  // MARK: - Dropdown menu

  /// Build the status-item dropdown as an `NSMenu` whose single item hosts the
  /// AppKit `DropdownContentView`. Menu tracking keeps the macOS menu bar revealed
  /// over a full-screen Space (a popover/panel can't); the AppKit controls track
  /// correctly inside the tracked menu. The menu supplies its own material
  /// background, rounded corners, item highlight, and outside-click dismissal.
  private func makeDropdownMenu() -> NSMenu {
    let menu = NSMenu()
    menu.delegate = self
    let item = NSMenuItem()
    let content = DropdownContentView(
      app: appState,
      onOpenControls: { [weak self] in self?.openControlsFromMenu() },
      onQuit: { [weak self] in self?.quitFromStatusBar(nil) })
    content.updateFrameToFit()
    item.view = content
    menu.addItem(item)
    dropdownContentView = content
    return menu
  }

  /// Refresh the dropdown just before it opens: re-read a connected light's values
  /// (or, mid auto-reconnect, bring the next attempt forward — but never resurrect
  /// a manual disconnect), and resize the hosted view to its current content
  /// (connected vs. disconnected differ in height).
  func menuWillOpen(_ menu: NSMenu) {
    appState.refreshOnOpen()
    dropdownContentView?.updateFrameToFit()
  }

  /// Close the dropdown, then open the full controls window. Deferred a tick so
  /// the menu's tracking loop has fully ended before we activate + show a window.
  private func openControlsFromMenu() {
    dropdownMenu?.cancelTracking()
    DispatchQueue.main.async { [weak self] in self?.openController(tab: .controls) }
  }

  // MARK: - Quit

  /// Status-bar Quit: set the flag so `applicationShouldTerminate` lets us exit.
  @objc func quitFromStatusBar(_ sender: Any?) {
    quitFromStatusBarMenu = true
    // Dismiss any open window/sheet first (e.g. the Discover sheet) — a presented
    // sheet can otherwise block termination — then quit.
    for window in NSApp.windows where window.level == .normal {
      window.close()
    }
    NSApp.terminate(sender)
  }

  // MARK: - Window

  /// Open (and build, first time) the controller window. Bump to `.regular` so
  /// it gets a Dock icon + can become key (tooltips need a key window under
  /// `.regular`).
  private func openController(tab: ControllerWindowController.Tab) {
    NSApp.setActivationPolicy(.regular)
    if windowController == nil {
      windowController = ControllerWindowController(appState: appState)
    }
    windowController?.show(tab: tab)
    // Activate AFTER the window is ordered front so macOS switches to the Space the
    // (normal desktop) window lives on — i.e. from a full-screen Space back to the
    // desktop. Activating first, before any window exists, gives it nothing to
    // switch to, so the user stays in full-screen (the reported bug).
    activateApp()
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
