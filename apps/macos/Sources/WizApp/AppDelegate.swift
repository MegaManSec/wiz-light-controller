import AppKit
import Combine
import SwiftUI
import WizKit

/// Application delegate: owns the status item, the controller window, and the
/// menu-bar lifecycle. Mirrors blue-switch's AppDelegate — the LSUIElement +
/// `.accessory` activation-policy dance, the manual window, and the quit
/// semantics that keep the app living in the menu bar.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
  // MARK: - State

  /// The single shared app state. The status item, menu, and views all read it.
  let appState = AppState()

  private var statusItem: NSStatusItem!
  /// The menu-bar dropdown, as a transient SwiftUI popover (live + animated).
  private var popover: NSPopover?
  /// Global mouse monitor that dismisses the popover when you click outside it.
  private var clickMonitor: Any?
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
    // `.help` tooltips have a long default initial-hover delay; shorten it to ~2s.
    UserDefaults.standard.set(2000, forKey: "NSInitialToolTipDelay")
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

  /// Bring the app forward. We deliberately use the (deprecated)
  /// `activate(ignoringOtherApps:)` rather than the newer no-argument
  /// `activate()`: a menu-bar agent must be able to surface its popover/window
  /// *over a full-screen app*, and the cooperative `activate()` refuses to take
  /// over another app's full-screen Space — the popover then never appears
  /// (and the controls window can open blank). The deprecation is acceptable
  /// for this reason; it remains the only call that reliably activates here.
  private func activateApp() {
    NSApp.activate(ignoringOtherApps: true)
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

  /// Single-click toggles the dropdown popover (closes it if already open).
  @objc private func handleClick(_ sender: NSStatusBarButton) {
    if let popover = popover, popover.isShown {
      popover.performClose(sender)
      return
    }
    let pop = popover ?? makePopover()
    popover = pop
    activateApp()
    pop.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
    // Keep the status button looking "pressed" while the popover is open. The
    // click's own highlight clears on mouse-up, so assert it next tick (guarded so
    // a quick open→close can't leave it stuck on).
    DispatchQueue.main.async { [weak self] in
      guard let self = self, self.popover?.isShown == true else { return }
      self.statusItem.button?.highlight(true)
      // Make the popover window key so its controls render in their active
      // (accent/blue) state — and, crucially, so `.help()` tooltips appear:
      // AppKit only shows tooltips for views in the key window. (A window can't
      // be key while its app is inactive, which is why `activateApp()` above is
      // the real fix; this just asserts key on the popover specifically.)
      self.popover?.contentViewController?.view.window?.makeKey()
    }
    // Refresh a connected light's values each time the dropdown opens — but don't
    // reconnect a disconnected one (so it never overrides a manual disconnect).
    appState.refreshIfConnected()
    // Dismiss when the user clicks outside (the desktop or another app); the
    // popover delegate tears this monitor down on close.
    clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) {
      [weak self] _ in self?.popover?.performClose(nil)
    }
  }

  /// Build the SwiftUI dropdown popover. Transient so it closes on an outside
  /// click; reused across opens and reflects live state via the shared AppState.
  private func makePopover() -> NSPopover {
    let pop = NSPopover()
    pop.behavior = .transient
    pop.animates = true
    pop.delegate = self
    let content = DropdownView(
      onOpenControls: { [weak self] in self?.openControlsFromPopover() },
      onQuit: { [weak self] in self?.quitFromStatusBar(nil) }
    ).environmentObject(appState)
    let host = NSHostingController(rootView: content)
    host.sizingOptions = [.preferredContentSize]  // smoother popover resize on mode switches
    pop.contentViewController = host
    return pop
  }

  /// Close the popover, then open the full controls window.
  private func openControlsFromPopover() {
    popover?.performClose(nil)
    openController(tab: .controls)
  }

  /// Tear down the outside-click monitor whenever the popover closes (any cause).
  func popoverDidClose(_ notification: Notification) {
    statusItem.button?.highlight(false)
    if let monitor = clickMonitor {
      NSEvent.removeMonitor(monitor)
      clickMonitor = nil
    }
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
    activateApp()
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
