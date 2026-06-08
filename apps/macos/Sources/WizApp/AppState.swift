import AppKit
import Combine
import Foundation
import Network
import SwiftUI
import WizKit

/// The single source of truth for the app: the shared `WizCore` engine, the
/// active light's `LightState`, the selected light's identity, presets, and
/// settings. The status item, menu, and SwiftUI views all observe this.
///
/// Pinned to the main actor because `WizCore` (a `JSContext`) is not
/// thread-safe — every engine call happens here. Network IO is dispatched off
/// the main thread inside `WizClient`/`Discovery` and hops back before mutating
/// published state.
@MainActor
final class AppState: ObservableObject {
  // MARK: - Engine + persistence

  /// The one `WizCore` instance — colour maths and the light-state model.
  let core = WizCore()
  private let stores = Stores()

  // MARK: - Published UI state

  /// Live light state shown in the controls. Mutations here drive `applyLive()`.
  @Published var state: LightState

  /// Selected light identity. `ip` is what we actually talk to; `mac` keys the
  /// saved-lights store; `name` is for display.
  @Published var selectedName: String = ""
  @Published var selectedIp: String = ""
  @Published var selectedMac: String = ""

  /// Saved lights, keyed by MAC. Mirrors `saved_lights.json`.
  @Published var savedLights: [String: Stores.SavedLight] = [:]

  /// Presets grouped by mode (rgb / white), from `presets.json` (seeded).
  @Published var presets: [LightMode: [Preset]] = [.rgb: [], .white: []]

  /// Persisted UI settings (accent / highlight / auto-sync).
  @Published var settings: Stores.Settings = .defaults

  /// Connection lifecycle for the selected light — the single source of truth for
  /// the status dot/text in both the controls window and the menu-bar popover.
  /// `connected` is *derived* from this (below) so the boolean and the displayed
  /// phase can never disagree. Transitions live in `sync`/`syncAttempt`,
  /// `reconnect`, `disconnect`, `selectLight`, and the health poll.
  enum ConnectionStatus: Equatable {
    /// No light selected (no IP).
    case noLight
    /// A connect/reconnect attempt is in flight (getPilot retrying).
    case connecting
    /// Last getPilot succeeded — the light is reachable.
    case connected
    /// Idle or dropped with nothing to report: selected-but-not-connected, a
    /// manual disconnect, or a transient health drop the poll will quietly retry.
    case disconnected
    /// A connect attempt gave up; carries a short reason for the UI to show.
    case error(String)
  }
  @Published private(set) var status: ConnectionStatus = .noLight

  /// True only while the light is reachable. Derived from `status`, so it can
  /// never contradict the phase the UI is showing.
  var connected: Bool { status == .connected }
  /// A connect/reconnect is in flight (drives the "Connecting…" spinner/label).
  var isConnecting: Bool { status == .connecting }
  /// The current phase is a failure (drives red error styling).
  var statusIsError: Bool { if case .error = status { return true } else { return false } }

  /// Short status text shared by the controls-window dot and the popover, e.g.
  /// "Connecting…", "Connected", or the error reason itself.
  var statusLabel: String {
    switch status {
    case .noLight: return "No light"
    case .connecting: return "Connecting…"
    case .connected: return "Connected"
    case .disconnected: return "Disconnected"
    case .error(let message): return message
    }
  }

  /// Read-only device info for Settings. `rssi` refreshes while connected; the
  /// rest (`mac` / `moduleName` / `firmware`) are read once per host on connect.
  @Published var deviceInfo = DeviceInfo()

  /// One-line capability summary (e.g. "RGB + tunable white 2700–6500 K"),
  /// derived by the engine from `getModelConfig` and remembered across launches.
  @Published var deviceSummary: String = ""

  struct DeviceInfo: Equatable {
    var mac = ""
    var moduleName = ""
    var firmware = ""
    var rssi: Int?  // dBm; nil when unknown
  }

  /// Discovery results (most-recent run), and whether a scan is in flight.
  @Published var discovered: [Discovery.Light] = []
  @Published var isDiscovering: Bool = false

  /// Which tab the controller window shows. Set by the menu before opening.
  @Published var selectedTab: ControllerWindowController.Tab = .controls

  /// Set by the menu-bar popover's "Discover" call-to-action to ask the controls
  /// window to pop the discovery sheet as soon as it's open. The window's
  /// `ConnectionBar` consumes (and clears) it.
  @Published var requestDiscovery = false

  /// Bumped whenever the status item should re-render its icon/tooltip/menu.
  /// AppDelegate observes this.
  @Published private(set) var revision: Int = 0

  // MARK: - Per-host client (rebuilt when the IP changes)

  private var client: WizClient?
  /// Background poll that auto-retries a dropped connection (see `sync`).
  private var reconnectTimer: DispatchSourceTimer?
  /// Set when the user explicitly disconnects, to stop the auto-reconnect poll
  /// from immediately re-establishing. Cleared by any explicit `sync`.
  private var manuallyDisconnected = false
  /// Current auto-reconnect delay. Grows from `reconnectBackoffFloor` toward
  /// `reconnectBackoffCeiling` with each failed attempt and is reset to the floor
  /// on a successful connect, a network change, or a user action. See `pollTick`.
  private var reconnectBackoff: TimeInterval = AppState.reconnectBackoffFloor
  /// Watches for network path changes (joining/switching Wi-Fi, VPN, etc.) so a
  /// dropped link is retried promptly instead of waiting out the backoff.
  private let pathMonitor = NWPathMonitor()
  /// Signature of the last network path, so duplicate updates are ignored and we
  /// react once per real change.
  private var lastNetworkSignature: String?
  /// Consecutive silent health pings while connected; we drop to disconnected
  /// once this reaches `maxHealthFailures` (so a single blip doesn't flap).
  private var healthFailures = 0
  /// When we last sent a local change. The connected poll won't fold the bulb's
  /// reported state back in until a few seconds after this, so changes made
  /// elsewhere (e.g. the phone app) surface without a poll yanking a control the
  /// user is actively adjusting.
  private var lastLocalEdit = Date.distantPast
  /// Last >0 brightness — restored when the light is turned on, so it doesn't come
  /// back at the ~1% you passed through on the way to off. Committed when a
  /// brightness drag is released (see `commitBrightnessMemory`), never as 0.
  private var lastBrightness = 100

  init() {
    // Seed from the engine's default before loading persisted state.
    self.state = core.defaultState
    loadPersisted()
    startReconnectPolling()
    startNetworkMonitor()
  }

  deinit {
    reconnectTimer?.cancel()
    pathMonitor.cancel()
  }

  /// The bulb's real white range, negotiated from `getModelConfig` (`cctRange`)
  /// on connect; `nil` until then. Published so the sliders update when it lands.
  @Published var negotiatedTempRange: ClosedRange<Int>?
  /// The host the negotiated config (range + device info) belongs to, so we
  /// re-read it when the IP changes.
  private var configHost: String?
  /// The bulb's real minimum dimming level (`minDimLevel`), negotiated on
  /// connect; `nil` until then (the engine's default floor applies meanwhile).
  private var negotiatedDimMin: Int?

  /// White-temperature range for the sliders: the bulb's negotiated range, else
  /// the engine default (2200…6500) until/if a bulb doesn't report one.
  var tempRange: ClosedRange<Int> { negotiatedTempRange ?? core.tempRange }

  /// Clamp a temperature to the bulb's real (negotiated) white range.
  func clampTemp(_ kelvin: Int) -> Int {
    max(tempRange.lowerBound, min(tempRange.upperBound, kelvin))
  }

  /// Per-device wire bounds for `buildSetPilotParams`: the negotiated white range
  /// and (when known) the bulb's real dimming floor. Omitted keys fall back to
  /// the engine's WiZ-standard defaults.
  private func deviceBounds() -> [String: Any] {
    var bounds: [String: Any] = ["tempMin": tempRange.lowerBound, "tempMax": tempRange.upperBound]
    if let dimMin = negotiatedDimMin { bounds["dimMin"] = dimMin }
    return bounds
  }

  // MARK: - Colour mode (RGB / White / Warm Glow)

  /// Three ways to drive the light. "Warm Glow" is a UI mode layered on white:
  /// you set only brightness and the temperature auto-follows the bulb's
  /// dim-to-warm curve (warmer as you dim).
  enum ColorMode: String, CaseIterable, Identifiable {
    case rgb, white, warmGlow, scene
    var id: String { rawValue }
    var label: String {
      switch self {
      case .rgb: return "RGB"
      case .white: return "White"
      case .warmGlow: return "Warm Glow"
      case .scene: return "Scenes"
      }
    }
    /// Modes shown in the compact menu-bar popover — scenes live only in the
    /// controls window, so they're excluded here.
    static let popoverModes: [ColorMode] = [.rgb, .white, .warmGlow]
  }

  /// True when Warm Glow is active (the wire mode is still white).
  @Published var warmGlow = false
  /// True while the brightness slider is being dragged — lets the locked Warm Glow
  /// temperature follow brightness down to its warmest end at 0, then settle to the
  /// saved level on release (a plain power-toggle leaves it put).
  @Published var isDraggingBrightness = false

  /// RGB-only: route a colour's achromatic part through the bulb's bright white
  /// channels for a much brighter, slightly less saturated result. Off = faithful
  /// pure RGB (the dimmer colour LEDs only). A per-session choice; not persisted.
  @Published var whiteMix = false

  /// Dynamic scenes this bulb can show, detected read-only from `getModelConfig` on
  /// connect. Empty until known, or for a device with no colour/white channels.
  @Published var availableScenes: [LightScene] = []

  /// The last scene applied, so re-entering Scenes mode restores it.
  private var sceneMemory: SceneRef?

  /// Brightness%→Kelvin dim-to-warm curve, read from the bulb's `dim2WarmPoints`
  /// (else this sensible default), sorted by brightness.
  private static let defaultDimToWarm: [(kelvin: Int, brightness: Int)] = [
    (1800, 1), (2700, 50), (4200, 100),
  ]
  private var dimToWarmCurve = AppState.defaultDimToWarm

  /// Per-mode memory so returning to a mode restores its last colour/temperature
  /// (e.g. switching through Warm Glow doesn't lose your White temperature).
  /// Session-scoped; reset when the selected light changes.
  private var rgbMemory: [Int]?
  private var whiteTempMemory: Int?

  /// The active mode for the picker.
  var colorMode: ColorMode {
    if state.scene != nil { return .scene }
    if warmGlow { return .warmGlow }
    return state.mode == .rgb ? .rgb : .white
  }

  /// Whether this bulb supports scenes (gates the controls-window Scenes mode).
  /// Detected read-only from `getModelConfig`; a running scene also proves it.
  var supportsScenes: Bool { !availableScenes.isEmpty || state.scene != nil }

  /// Modes offered by the controls-window picker — Scenes only when supported.
  var controlsModes: [ColorMode] {
    supportsScenes ? ColorMode.allCases : ColorMode.allCases.filter { $0 != .scene }
  }

  /// Switch modes, remembering the colour/temperature of the mode we leave and
  /// restoring the one we return to (so passing through Warm Glow doesn't lose
  /// your White temperature). Warm Glow snaps the temperature to the curve.
  func setColorMode(_ mode: ColorMode) {
    switch colorMode {  // remember what we're leaving
    case .rgb: rgbMemory = state.rgb
    case .white: whiteTempMemory = state.temp
    case .warmGlow: break  // temperature is derived from brightness; nothing to save
    case .scene: sceneMemory = state.scene
    }
    // Any non-scene mode exits a running scene (sending colour/temp clears it on
    // the bulb); entering Scenes restores the last (or first available) one.
    if mode != .scene { state.scene = nil }
    switch mode {
    case .rgb:
      warmGlow = false
      state.mode = .rgb
      if let rgb = rgbMemory { state.rgb = rgb }
    case .white:
      warmGlow = false
      state.mode = .white
      if let temp = whiteTempMemory { state.temp = clampTemp(temp) }
    case .warmGlow:
      warmGlow = true
      state.mode = .white
      state.temp = kelvinForBrightness(state.brightness)
    case .scene:
      warmGlow = false
      state.scene = sceneMemory ?? SceneRef(id: availableScenes.first?.id ?? 4)
    }
    applyLive()
    reconcileSoon()
  }

  /// Set brightness; in Warm Glow the temperature follows the curve. Caller sends.
  func setBrightness(_ value: Int) {
    state.brightness = core.clampBrightness(value)
    if warmGlow { state.temp = kelvinForBrightness(state.brightness) }
  }

  /// Remember the current brightness as the level to restore on power-on — called
  /// when a brightness drag is released. Never remembers 0 ("off"), so dragging
  /// down to off leaves the previous level intact.
  func commitBrightnessMemory() {
    if state.on, state.brightness > 0 { lastBrightness = state.brightness }
  }

  /// Toggle white-mixing and re-send immediately so the brightness change shows.
  func setWhiteMix(_ on: Bool) {
    whiteMix = on
    applyLive()
  }

  /// Set brightness from a slider. 0 turns the light off; any positive value sets
  /// the brightness, turning the light back on if it was off. Sends immediately.
  func setBrightnessLevel(_ value: Int) {
    let v = core.clampBrightness(value)
    if v <= 0 {
      if state.on { setPower(false) }
      return
    }
    let wasOff = !state.on
    setBrightness(v)
    if wasOff { state.on = true }
    applyLive()
  }

  /// Map brightness → Kelvin for Warm Glow via the shared engine — one tested
  /// implementation (stretches the curve's clamped Kelvin span across the whole
  /// brightness range).
  func kelvinForBrightness(_ brightness: Int) -> Int {
    // Brightness 0 is "off", so the usable Warm Glow range is 1…100 — map that
    // onto the curve's full span so 1 lands on the device's warmest temperature
    // (e.g. 2700 K) and 100 on its coolest, rather than 1 sitting just above warm.
    let usable = max(1, min(100, brightness))
    let scaled = Int((Double(usable - 1) / 99 * 100).rounded())
    return core.warmGlowKelvin(scaled, curve: dimToWarmCurve, range: tempRange)
  }

  /// The colour temperature Warm Glow displays: the live brightness's curve value
  /// when on, or the saved restore level's when off — so sliding brightness to 0
  /// doesn't strand the locked Temperature slider at a stale value.
  var warmGlowDisplayKelvin: Int {
    if state.on { return kelvinForBrightness(state.brightness) }
    // Off: while still dragging brightness, follow it down to the warmest (lowest)
    // end (0); once settled — drag released or toggled off — sit at the saved level.
    return kelvinForBrightness(isDraggingBrightness ? 0 : lastBrightness)
  }

  // MARK: - Persistence

  /// Load everything from disk and pick an initial light (last IP, matched to a
  /// saved light when possible). Called once at init.
  func loadPersisted() {
    settings = stores.loadSettings()
    savedLights = stores.loadSavedLights()
    presets = stores.loadPresets(defaults: core.defaultPresets())

    // Only restore a *saved* light (lights are added via Discover → Save): the
    // last-used one by IP, else any saved light. With nothing saved, nothing is
    // selected — so we never show a phantom "press Connect to control …" for a
    // light that isn't saved.
    let lastIp = stores.loadLastIp()
    if !lastIp.isEmpty, let (mac, light) = savedLights.first(where: { $0.value.ip == lastIp }) {
      selectLight(name: light.name, ip: light.ip, mac: mac, persistIp: false)
    } else if let (mac, light) = savedLights.first {
      selectLight(name: light.name, ip: light.ip, mac: mac, persistIp: false)
    }

    // Surface the bulb's remembered identity (model / MAC / firmware) right away
    // — in the menu header and Settings → Device — before the first connect
    // refreshes it (selectLight cleared deviceInfo). Live-only fields like signal
    // stay blank until connected.
    if hasLight, let id = stores.loadLastDevice(forIp: selectedIp) {
      deviceInfo.mac = id.mac
      deviceInfo.moduleName = id.moduleName
      deviceInfo.firmware = id.firmware
      deviceSummary = id.summary
    }

    // Seed the wheel with this device's last colour (per-device memory), now
    // that its MAC is known — from the saved light or the restored identity.
    if hasLight, !activeMac.isEmpty, let rgb = stores.loadDeviceRgb(activeMac) {
      state.rgb = rgb
    }
  }

  /// Persist the mutable, user-facing state (settings, presets, saved lights,
  /// last IP/RGB). Cheap enough to call after any edit.
  func persist() {
    stores.saveSettings(settings)
    stores.savePresets(presets)
    stores.saveSavedLights(savedLights)
    if !selectedIp.isEmpty { stores.saveLastIp(selectedIp) }
    if state.mode == .rgb, !activeMac.isEmpty { stores.saveDeviceRgb(state.rgb, forMac: activeMac) }
  }

  // MARK: - Light selection

  /// Point the app at a light. Rebuilds the per-host client and remembers the IP.
  func selectLight(
    name: String, ip: String, mac: String, persistIp: Bool = true, connect: Bool = true
  ) {
    // A (re)selected light is a fresh start — clear any grown reconnect backoff.
    resetReconnectBackoff()
    // An empty name is kept empty (not defaulted to the IP) so `displayName` can
    // fall back to the bulb's module name instead of rendering "IP — IP".
    selectedName = name
    selectedIp = ip
    selectedMac = mac
    client = ip.isEmpty ? nil : WizClient(host: ip)
    if persistIp, !ip.isEmpty { stores.saveLastIp(ip) }
    // A new host has its own connection, range + device info; drop the previous
    // light's until we re-confirm/re-read them on connect, so its state can't be
    // shown (or sent) under the newly selected light during the brief sync.
    if configHost != ip {
      negotiatedTempRange = nil
      negotiatedDimMin = nil
      deviceInfo = DeviceInfo()
      deviceSummary = ""
      dimToWarmCurve = AppState.defaultDimToWarm
      warmGlow = false
      rgbMemory = nil
      whiteTempMemory = nil
      availableScenes = []
      configHost = nil
    }
    if connect {
      bump()
      // Selecting a light attempts to connect (and reflect its state), so a valid,
      // reachable IP turns green without a manual sync.
      if hasLight { sync() } else { status = .noLight; bump() }
    } else {
      // Selected without connecting — leave it disconnected until the user
      // explicitly connects (Controls → Connect), and don't auto-reconnect.
      manuallyDisconnected = true
      status = hasLight ? .disconnected : .noLight
      bump()
    }
  }

  /// True when an IP is set and valid.
  var hasLight: Bool { !selectedIp.isEmpty && core.isValidIp(selectedIp) }

  /// Human label for the active light: the user's saved name, else the bulb's
  /// reported module name (negotiated on connect, remembered across launches),
  /// else the IP. Never empty while `hasLight`.
  var displayName: String {
    if !selectedName.isEmpty { return selectedName }
    if !deviceInfo.moduleName.isEmpty { return deviceInfo.moduleName }
    return selectedIp
  }

  /// The active light's MAC — the explicit saved-light MAC, else the one learned
  /// from (or remembered for) the bulb on connect. Keys per-device memory such
  /// as the remembered colour; empty until we know it.
  private var activeMac: String { selectedMac.isEmpty ? deviceInfo.mac : selectedMac }

  // MARK: - Querying the light

  /// Number of `getPilot` attempts before settling on "disconnected".
  private static let maxSyncAttempts = 4
  /// Consecutive silent health pings (15 s apart) before declaring a drop (≈45 s).
  private static let maxHealthFailures = 3
  /// `getPilot` probes per health check before a tick counts as silent. A lone
  /// dropped datagram or a firmware micro-sleep shouldn't read as a failure, so a
  /// probe retries (like `sync`'s connect and WizClient's 3× sends) before the
  /// 15 s tick is allowed to add a strike toward `maxHealthFailures`.
  private static let healthProbeAttempts = 3
  /// Gap between those probes — long enough to let a micro-sleeping bulb wake,
  /// short enough that a real drop still settles well within the 15 s cadence.
  private static let healthProbeRetryMs = 150
  /// The connected health-check cadence: a `getPilot` every 15 s (see `pollTick`).
  private static let healthPollInterval: TimeInterval = 15
  /// Auto-reconnect backoff bounds. After a drop we retry after `floor` seconds,
  /// doubling each failed attempt up to `ceiling` (5 min), so a bulb that's
  /// powered off or out of range isn't probed every 15 s forever. Reset to the
  /// floor on a successful connect, a network change, or a user action.
  private static let reconnectBackoffFloor: TimeInterval = 15
  private static let reconnectBackoffCeiling: TimeInterval = 300

  /// Query the bulb (`getPilot`) and fold the result into `state`, updating
  /// `connected`. Retries a few times on failure so a valid, reachable bulb
  /// reliably turns green even when the first datagram races macOS's
  /// Local-Network permission prompt (or hits transient UDP loss). No-op without
  /// a valid IP.
  func sync() {
    // Any explicit sync is an intent to connect — clear a manual disconnect.
    manuallyDisconnected = false
    guard hasLight else {
      status = .noLight
      bump()
      return
    }
    // Show "Connecting…" right away; syncAttempt resolves to .connected or .error.
    status = .connecting
    bump()
    syncAttempt(host: selectedIp, attempt: 0)
  }

  /// Called when a UI surface opens (the menu-bar dropdown, or the controls
  /// window under auto-sync). Two cases:
  ///
  /// - **Connected:** re-read the bulb's values via `monitorHealth: false`, so an
  ///   off-cadence open only *reads* fresh values (and clears stale strikes on a
  ///   reply) — it can never itself disconnect you; only the 15 s poll drops the
  ///   link.
  /// - **Mid auto-reconnect** (dropped but not *manually* disconnected): treat the
  ///   open as a fresh chance to reach the bulb — reset the backoff and pull the
  ///   next attempt forward (~0.5 s), so the user doesn't sit watching a backoff
  ///   that may have grown to minutes. Same bring-forward as `handlePathChange`;
  ///   `pollTick` owns the connect guards and won't stack onto an in-flight
  ///   attempt, so we just reschedule.
  ///
  /// A deliberate disconnect (and a no-light state) is left alone, so opening the
  /// menu never overrides it — the same invariant the poll and network-change
  /// paths honour.
  func refreshOnOpen() {
    if connected {
      refreshSignal(monitorHealth: false)
    } else if hasLight, !manuallyDisconnected {
      resetReconnectBackoff()
      scheduleNextPoll(after: 0.5)
    }
  }

  /// Warm Glow is a local overlay on white mode (the temperature follows the
  /// brightness curve); the bulb — and another app driving it — can't report it.
  /// So after folding in a fresh read, drop out of Warm Glow if that read is RGB,
  /// or its white temperature no longer tracks the curve (someone changed the
  /// mode/temperature elsewhere). Otherwise `colorMode` stays stuck on `.warmGlow`
  /// (it overrides `state.mode`) and the dropdown + controls show the wrong
  /// mode/colour.
  private func reconcileWarmGlow(with next: LightState) {
    guard warmGlow else { return }
    if next.mode == .rgb || abs(next.temp - kelvinForBrightness(next.brightness)) > 50 {
      warmGlow = false
    }
  }

  /// Fold the bulb's white channels (`c`/`w`) into the displayed RGB. The engine
  /// infers control state from r/g/b alone (model.js `parsePilot`), so a colour the
  /// bulb renders with its white LEDs — a pastel, or anything set from the phone
  /// app — reads back over-saturated; this recombines them so the swatch and hex
  /// match what the eye sees. RGB mode only, and a no-op when no white is lit.
  private func perceivedState(_ parsed: LightState, from result: [String: Any]) -> LightState {
    guard parsed.mode == .rgb else { return parsed }
    let c = (result["c"] as? NSNumber)?.intValue ?? 0
    let w = (result["w"] as? NSNumber)?.intValue ?? 0
    guard c != 0 || w != 0 else { return parsed }
    var next = parsed
    next.rgb = core.perceivedRgb(parsed.rgb, c: c, w: w)
    return next
  }

  private func syncAttempt(host: String, attempt: Int) {
    guard selectedIp == host, let client = client else { return }
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      let result = client.getPilot(host: host)
      DispatchQueue.main.async {
        // Drop a stale result if the user switched lights mid-flight.
        guard let self = self, self.selectedIp == host else { return }
        if let result = result, let parsed = self.core.parsePilot(result) {
          self.status = .connected
          self.healthFailures = 0
          // Reconnected: clear the backoff and resume the 15 s health cadence now
          // (the pending tick may be a long backoff out after a lengthy outage).
          self.reconnectBackoff = Self.reconnectBackoffFloor
          self.scheduleNextPoll(after: Self.healthPollInterval)
          // Preserve the user's last RGB if the bulb reports white mode (so
          // flipping back to RGB restores their colour rather than white).
          var next = self.perceivedState(parsed, from: result)
          if next.mode == .white { next.rgb = self.state.rgb }
          // A running scene reports no colour; keep the last one so leaving it restores.
          if next.scene != nil {
            next.rgb = self.state.rgb
            next.temp = self.state.temp
          }
          self.state = next
          self.reconcileWarmGlow(with: next)
          if next.on, next.brightness > 0 { self.lastBrightness = next.brightness }
          self.deviceInfo.rssi = (result["rssi"] as? NSNumber)?.intValue ?? self.deviceInfo.rssi
          self.loadDeviceConfig(host: host, client: client)
          self.bump()
        } else if attempt + 1 < Self.maxSyncAttempts {
          DispatchQueue.main.asyncAfter(deadline: .now() + 1.3) { [weak self] in
            self?.syncAttempt(host: host, attempt: attempt + 1)
          }
        } else {
          self.status = .error("Couldn't reach \(self.displayName)")
          self.bump()
        }
      }
    }
  }

  /// Read the bulb's capabilities + identity once per host: `getModelConfig`
  /// (`cctRange` → white range) and `getSystemConfig` (mac / model / firmware).
  /// Runs off-main; applies on main only if the host is still selected.
  private func loadDeviceConfig(host: String, client: WizClient) {
    if configHost == host { return }
    configHost = host  // claim it so repeated syncs don't fire duplicate queries
    DispatchQueue.global(qos: .utility).async { [weak self] in
      // Network IO off-main; parsing happens on-main below because the shared
      // engine (a JSContext) is single-threaded.
      let model = client.getModelConfig(host: host)
      let system = client.getSystemConfig(host: host)
      let user = client.getUserConfig(host: host)
      DispatchQueue.main.async {
        guard let self = self, self.selectedIp == host else { return }
        // One parser, shared with the CLI: the engine's deviceBoundsFromConfig /
        // dimToWarmCurveFromConfig, run via JavaScriptCore.
        if let model = model {
          let bounds = self.core.deviceBounds(model)
          if let lo = bounds.tempMin, let hi = bounds.tempMax, lo < hi {
            self.negotiatedTempRange = lo...hi
          }
          if let dimMin = bounds.dimMin, dimMin > 0 { self.negotiatedDimMin = dimMin }
          self.deviceSummary = self.core.describeDevice(model)
          // Detect scene support read-only: offer scenes only for a bulb with
          // colour or white channels (not, say, a smart plug).
          let caps = self.core.deviceCapabilities(model)
          self.availableScenes = caps.rgb || caps.white ? self.core.scenesForDevice(model) : []
        }
        if let user = user {
          let curve = self.core.dimToWarmCurve(user)
          if !curve.isEmpty { self.dimToWarmCurve = curve }
        }
        if let system = system {
          if let mac = system["mac"] as? String {
            self.deviceInfo.mac = mac
            // Restore this device's remembered colour for a white→RGB flip; the
            // bulb's own colour already wins while it's actually in RGB mode.
            if self.state.mode == .white, let rgb = self.stores.loadDeviceRgb(mac) {
              self.state.rgb = rgb
            }
          }
          if let module = system["moduleName"] as? String { self.deviceInfo.moduleName = module }
          if let fw = system["fwVersion"] as? String { self.deviceInfo.firmware = fw }
          // Remember the identity so the header + Settings show it on next launch.
          self.stores.saveLastDevice(
            ip: host, mac: self.deviceInfo.mac, moduleName: self.deviceInfo.moduleName,
            firmware: self.deviceInfo.firmware, summary: self.deviceSummary)
        }
        if model == nil, system == nil, user == nil {
          self.configHost = nil  // all failed — retry on the next sync
        }
        self.bump()
      }
    }
  }

  /// Force a fresh connection: rebuild the per-host client (new socket) and
  /// re-sync, adopting the bulb's current colour / brightness / mode. Recovers a
  /// stuck "Disconnected" state and refreshes the local controls on reconnect.
  func reconnect() {
    guard hasLight else {
      status = .noLight
      bump()
      return
    }
    resetReconnectBackoff()
    status = .connecting
    client = WizClient(host: selectedIp)
    bump()
    sync()
  }

  /// Stop controlling the current light: mark it disconnected and suppress the
  /// auto-reconnect poll until the user reconnects (Reconnect / re-select / Sync).
  func disconnect() {
    guard hasLight else { return }
    manuallyDisconnected = true
    status = .disconnected
    healthFailures = 0
    resetReconnectBackoff()
    bump()
  }

  /// A housekeeping poll that re-arms itself each tick, so its cadence can vary.
  /// While connected it health-checks the link every `healthPollInterval` via
  /// `refreshSignal` (a reply refreshes the signal; a few consecutive silences
  /// drop it). While disconnected it quietly retries the connection — so a
  /// transient drop (micro-sleep, Wi-Fi blip, the first-launch Local-Network
  /// prompt) heals without the user hitting Reconnect — on a backoff that doubles
  /// from `reconnectBackoffFloor` to `reconnectBackoffCeiling`, so a bulb that's
  /// powered off or out of range isn't probed every 15 s indefinitely.
  private func startReconnectPolling() {
    scheduleNextPoll(after: Self.healthPollInterval)
  }

  /// Arm a one-shot poll `interval` seconds out, replacing any pending tick.
  private func scheduleNextPoll(after interval: TimeInterval) {
    reconnectTimer?.cancel()
    let timer = DispatchSource.makeTimerSource(queue: .main)
    timer.schedule(deadline: .now() + interval)
    timer.setEventHandler { [weak self] in self?.pollTick() }
    timer.resume()
    reconnectTimer = timer
  }

  /// One poll iteration: health-check while connected, retry-with-backoff while
  /// dropped, idle otherwise — then re-arm the next tick at the right cadence.
  private func pollTick() {
    guard hasLight else {
      scheduleNextPoll(after: Self.healthPollInterval)  // nothing to do; re-check later
      return
    }
    if connected {
      refreshSignal(monitorHealth: true)
      scheduleNextPoll(after: Self.healthPollInterval)
    } else if manuallyDisconnected {
      scheduleNextPoll(after: Self.healthPollInterval)  // idle until the user reconnects
    } else if isConnecting {
      // A connect attempt is already in flight (e.g. a network-change tick landed
      // mid-sync) — don't stack another; check back at the base cadence. `sync`
      // always resolves within ~10 s, so this can't stall the poll.
      scheduleNextPoll(after: Self.healthPollInterval)
    } else {
      // Dropped (or never reached): retry now, then back off the next attempt. A
      // successful connect (`syncAttempt`), a network change (`handlePathChange`),
      // or a user action resets `reconnectBackoff` to the floor.
      sync()
      reconnectBackoff = min(reconnectBackoff * 2, Self.reconnectBackoffCeiling)
      scheduleNextPoll(after: reconnectBackoff)
    }
  }

  /// Reset the auto-reconnect backoff to its floor (fast retries again).
  private func resetReconnectBackoff() { reconnectBackoff = Self.reconnectBackoffFloor }

  /// Start watching the network path. Joining or switching Wi-Fi (or any change
  /// to a usable path) is a fresh chance to reach the bulb, so we reset the
  /// backoff and bring the next reconnect attempt forward rather than waiting out
  /// a backoff that may have grown to minutes while we were away.
  private func startNetworkMonitor() {
    pathMonitor.pathUpdateHandler = { [weak self] path in
      // NWPathMonitor calls back on its own queue; AppState is main-actor isolated.
      Task { @MainActor in self?.handlePathChange(path) }
    }
    pathMonitor.start(queue: DispatchQueue.global(qos: .utility))
  }

  /// React to a network path change. Ignores duplicate updates (the OS emits
  /// several while an interface flaps) and only acts on a usable path: it resets
  /// the backoff and pulls the next poll forward, so a dropped link reconnects
  /// within a second of rejoining a network instead of minutes later.
  private func handlePathChange(_ path: NWPath) {
    let signature =
      "\(path.status):"
      + path.availableInterfaces.map(\.name).sorted().joined(separator: ",")
    guard signature != lastNetworkSignature else { return }
    lastNetworkSignature = signature
    guard path.status == .satisfied else { return }
    resetReconnectBackoff()
    // A usable network just appeared — bring the next poll forward so we retry
    // promptly instead of waiting out a backoff grown to minutes. `pollTick` owns
    // the connect guards and won't stack onto an in-flight attempt, so we just
    // reschedule. Skip while connected (the health poll covers it) or after a
    // manual disconnect.
    if hasLight, !manuallyDisconnected, !connected {
      scheduleNextPoll(after: 0.5)
    }
  }

  /// Health check + state refresh for the connected poll. A reply refreshes the
  /// signal, resets the failure count, and — unless the user just made a local
  /// edit — folds the bulb's reported state back in, so changes made elsewhere
  /// (e.g. the phone app) show up here too. Each call probes `getPilot` up to
  /// `healthProbeAttempts` times so a single dropped datagram or micro-sleep isn't
  /// mistaken for silence; only when `monitorHealth` is set (the 15 s timer) does a
  /// fully silent probe add a strike, and `maxHealthFailures` consecutive silent
  /// ticks then flip us to disconnected.
  private func refreshSignal(monitorHealth: Bool) {
    guard let client = client else { return }
    let host = selectedIp
    // Read the actor-isolated tunables into locals up front (like `host`) so the
    // off-main probe closure can use them.
    let (attempts, retryMs) = (Self.healthProbeAttempts, Self.healthProbeRetryMs)
    DispatchQueue.global(qos: .utility).async { [weak self] in
      // Probe a few times before treating the bulb as silent — riding out a lone
      // dropped datagram the way `sync` and WizClient's repeated sends do, so a
      // healthy-but-blippy bulb doesn't flap the connection.
      var result: [String: Any]?
      for attempt in 0..<attempts {
        result = client.getPilot(host: host)
        if result != nil { break }
        if attempt < attempts - 1 {
          Thread.sleep(forTimeInterval: Double(retryMs) / 1000)
        }
      }
      DispatchQueue.main.async {
        guard let self = self, self.selectedIp == host, self.connected else { return }
        if let result = result {
          self.healthFailures = 0
          if let rssi = (result["rssi"] as? NSNumber)?.intValue { self.deviceInfo.rssi = rssi }
          // Reflect changes made elsewhere (e.g. the phone app), but never yank a
          // control mid-edit: only fold the bulb's state in once a few seconds
          // have passed since our last send (which it has since adopted).
          if Date().timeIntervalSince(self.lastLocalEdit) > 3,
            let parsed = self.core.parsePilot(result)
          {
            var next = self.perceivedState(parsed, from: result)
            if next.mode == .white { next.rgb = self.state.rgb }
            if next.scene != nil {
              next.rgb = self.state.rgb
              next.temp = self.state.temp
            }
            // While the light is off, the user may be staging a colour to apply
            // when they turn it back up — don't let the poll overwrite it. Fold
            // only when the bulb is on, or an on/off flip happened elsewhere.
            if self.state.on || next.on, next != self.state {
              self.state = next
              self.reconcileWarmGlow(with: next)
            }
            if next.on, next.brightness > 0 { self.lastBrightness = next.brightness }
          }
          self.bump()
        } else if monitorHealth {
          self.healthFailures += 1
          if self.healthFailures >= Self.maxHealthFailures {
            self.healthFailures = 0
            self.status = .disconnected
            self.bump()
          }
        }
      }
    }
  }

  // MARK: - Commands (debounced via WizClient)

  /// After a discrete change (mode switch, scene, preset) is pushed, read the bulb
  /// back once it's had a moment to apply — so the UI settles to the values the
  /// light *actually* adopted (a scene's real colours, a device-clamped
  /// temperature) instead of waiting up to 15 s for the housekeeping poll. Two
  /// staggered reads ride out the send debounce + a dropped datagram; each folds in
  /// only if no newer local edit has happened since, so it never yanks a slider the
  /// user started dragging in between.
  func reconcileSoon() {
    guard connected, client != nil else { return }
    let host = selectedIp
    let editToken = lastLocalEdit
    for delay in [0.7, 1.6] {
      DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
        guard let self = self, self.lastLocalEdit == editToken else { return }
        self.readback(host: host, editToken: editToken)
      }
    }
  }

  /// One post-change read-back: fold the bulb's reported state in (unlike the poll,
  /// without the 3 s quiet-window wait — the user expects the click to settle to the
  /// device's truth), but bail if a newer local edit has superseded it.
  private func readback(host: String, editToken: Date) {
    guard selectedIp == host, connected, let client = client else { return }
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      let result = client.getPilot(host: host)
      DispatchQueue.main.async {
        guard let self = self, self.selectedIp == host, self.connected,
          self.lastLocalEdit == editToken,
          let result = result, let parsed = self.core.parsePilot(result)
        else { return }
        var next = self.perceivedState(parsed, from: result)
        if next.mode == .white { next.rgb = self.state.rgb }
        if next.scene != nil {
          next.rgb = self.state.rgb
          next.temp = self.state.temp
        }
        if self.state.on || next.on, next != self.state {
          self.state = next
          self.reconcileWarmGlow(with: next)
        }
        if next.on, next.brightness > 0 { self.lastBrightness = next.brightness }
        self.bump()
      }
    }
  }

  /// Push the current `state` to the bulb (debounced + retried in `WizClient`).
  func applyLive() {
    guard let client = client else { return }
    lastLocalEdit = Date()
    let params = core.buildSetPilotParams(state, bounds: deviceBounds(), whiteMix: whiteMix)
    client.apply(state: state, params: params)
    if state.mode == .rgb { scheduleDeviceRgbSave() }
    bump()
  }

  /// Coalesce the per-device "last colour" persistence. A colour drag calls
  /// `applyLive` every frame, but the on-disk RGB only needs the settled value, so
  /// debounce the write — the live network send is already debounced in WizClient.
  private var rgbSaveGen = 0
  private func scheduleDeviceRgbSave() {
    guard !activeMac.isEmpty else { return }
    rgbSaveGen += 1
    let (gen, rgb, mac) = (rgbSaveGen, state.rgb, activeMac)
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
      guard let self, gen == self.rgbSaveGen else { return }
      self.stores.saveDeviceRgb(rgb, forMac: mac)
    }
  }

  /// Toggle power. Turning on restores the last settled brightness (so it doesn't
  /// return at the ~1% passed through on the way to off) and re-sends the full
  /// state; turning off is a bare power-off.
  func setPower(_ on: Bool) {
    lastLocalEdit = Date()
    if on {
      if lastBrightness > 0 { setBrightness(lastBrightness) }  // also recomputes Warm Glow temp
      state.on = true
      applyLive()
    } else {
      state.on = false
      guard let client = client else { bump(); return }
      client.power(false)
      bump()
    }
  }

  /// Apply a preset to the current state (via the engine), then send it.
  func applyPreset(_ preset: Preset) {
    state = core.applyPreset(state, preset)
    // Presets carry fixed temperatures that can fall outside this bulb's range
    // (e.g. 2200K on a 2700K-min strip), so clamp to the negotiated device range.
    if state.mode == .white { state.temp = clampTemp(state.temp) }
    commitBrightnessMemory()
    applyLive()
    reconcileSoon()
  }

  /// True if the live state matches `preset` (drives the active highlight).
  func isActive(_ preset: Preset) -> Bool {
    var p = preset
    // Match against the device-clamped temperature (presets can specify a temp
    // outside this bulb's range), so the preset you applied still highlights.
    if p.mode == .white, let temp = p.temp { p.temp = clampTemp(temp) }
    return core.stateMatchesPreset(state, p)
  }

  /// Save the current state as a preset under `name` in the current mode,
  /// replacing any existing same-name preset. Persists immediately.
  func saveCurrentAsPreset(name: String) {
    let trimmed = name.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty else { return }
    let preset: Preset
    if state.mode == .rgb {
      preset = Preset(
        name: trimmed, mode: .rgb,
        r: state.rgb[0], g: state.rgb[1], b: state.rgb[2], brightness: state.brightness)
    } else {
      preset = Preset(name: trimmed, mode: .white, temp: state.temp, brightness: state.brightness)
    }
    var group = presets[state.mode] ?? []
    group.removeAll { $0.name == trimmed }
    group.append(preset)
    group.sort { $0.name < $1.name }
    presets[state.mode] = group
    stores.savePresets(presets)
    bump()
  }

  /// Remove a preset by identity.
  func deletePreset(_ preset: Preset) {
    presets[preset.mode]?.removeAll { $0.name == preset.name }
    stores.savePresets(presets)
    bump()
  }

  // MARK: - Warm Glow presets

  /// Warm Glow presets are brightness levels (the temperature auto-follows the
  /// dim-to-warm curve), so they live here — Warm Glow is a UI mode — rather than
  /// in the engine's RGB/white presets.
  struct WarmGlowPreset: Identifiable {
    let name: String
    let brightness: Int
    var id: String { name }
  }

  let warmGlowPresets: [WarmGlowPreset] = [
    .init(name: "Candle", brightness: 10),
    .init(name: "Ember", brightness: 30),
    .init(name: "Cozy", brightness: 55),
    .init(name: "Hearth", brightness: 80),
    .init(name: "Glow", brightness: 100),
  ]

  /// Apply a Warm Glow preset: switch to Warm Glow at its brightness (the
  /// temperature follows), turn on, and send.
  func applyWarmGlowPreset(_ preset: WarmGlowPreset) {
    warmGlow = true
    state.scene = nil
    state.mode = .white
    state.on = true
    setBrightness(preset.brightness)
    commitBrightnessMemory()
    applyLive()
  }

  // MARK: - Scenes

  /// Run a dynamic scene (turns the light on). Keeps the current speed unless one
  /// is given; remembers the choice so re-entering Scenes mode restores it.
  func applyScene(_ id: Int, speed: Int? = nil) {
    state.on = true
    state.scene = SceneRef(id: id, speed: speed ?? state.scene?.speed)
    sceneMemory = state.scene
    applyLive()
    reconcileSoon()
  }

  /// Set the running scene's animation speed (10–200). No-op without a scene.
  func setSceneSpeed(_ speed: Int) {
    guard state.scene != nil else { return }
    state.scene?.speed = core.clampSpeed(speed)
    sceneMemory = state.scene
    applyLive()
  }

  /// True if `id` is the running scene (drives the active highlight).
  func isSceneActive(_ id: Int) -> Bool { state.scene?.id == id }

  // MARK: - Saved lights

  func saveCurrentLight(name: String) {
    guard !selectedMac.isEmpty else { return }
    savedLights[selectedMac] = Stores.SavedLight(name: name, ip: selectedIp)
    stores.saveSavedLights(savedLights)
    selectedName = name
    bump()
  }

  /// Save a specific discovered light (by MAC) without selecting or connecting —
  /// the Found → Save step. It then appears under Saved, where it can be selected.
  func saveLight(name: String, ip: String, mac: String) {
    guard !mac.isEmpty else { return }
    savedLights[mac] = Stores.SavedLight(name: name, ip: ip)
    stores.saveSavedLights(savedLights)
    bump()
  }

  func renameSavedLight(mac: String, name: String) {
    guard var light = savedLights[mac] else { return }
    light.name = name
    savedLights[mac] = light
    stores.saveSavedLights(savedLights)
    if mac == selectedMac { selectedName = name }
    bump()
  }

  func removeSavedLight(mac: String) {
    savedLights.removeValue(forKey: mac)
    stores.saveSavedLights(savedLights)
    if mac == selectedMac {
      // Removed the light we're using: clear the selection + disconnect, and forget
      // it as the last-used light, so nothing shows as selected or connected.
      stores.saveLastIp("")
      selectLight(name: "", ip: "", mac: "", persistIp: false, connect: false)
    }
    bump()
  }

  // MARK: - Discovery

  /// Broadcast for bulbs. On each result, auto-update a saved light's IP when
  /// its MAC reappears on a new address.
  func discover() {
    guard !isDiscovering else { return }
    isDiscovering = true
    discovered = []
    Discovery.discover { [weak self] lights in
      guard let self = self else { return }
      self.discovered = lights
      self.isDiscovering = false
      for light in lights where !light.mac.isEmpty {
        if self.savedLights[light.mac] != nil {
          self.savedLights = self.stores.updateSavedLightIp(mac: light.mac, ip: light.ip)
          if light.mac == self.selectedMac, self.selectedIp != light.ip {
            // Follow the new IP, but don't reconnect a manually-disconnected light.
            self.selectLight(
              name: self.selectedName, ip: light.ip, mac: light.mac,
              connect: !self.manuallyDisconnected)
          }
        }
      }
      self.bump()
    }
  }

  // MARK: - Colour editing (RGB / HSV / hex kept in sync via the engine)

  /// Current colour as HSV (h:0–360, s:0–100, v:0–100), derived from `state.rgb`
  /// through the engine. Used to drive the HSV sliders.
  var hsv: (h: Double, s: Double, v: Double) {
    let raw = core.rgbToHsv(state.rgb)  // h:0–1, s:0–1, v:0–1
    return (raw[0] * 360, raw[1] * 100, raw[2] * 100)
  }

  /// Hex string for the current RGB.
  var hex: String { core.rgbToHex(state.rgb) }

  /// Set RGB directly (slider / entry edits), clamp to bytes, re-send.
  func setRGB(_ rgb: [Int]) {
    let clamped = rgb.map { max(0, min(255, $0)) }
    // Black isn't a colour the bulb can show (it'd just be off), so reject it.
    // Every colour path (wheel / RGB / HSV / hex) funnels through here, so this
    // guards them all.
    if clamped == [0, 0, 0] { return }
    state.rgb = clamped
    state.mode = .rgb
    state.scene = nil  // picking a colour exits any active scene
    applyLive()
  }

  /// Set from HSV inputs (degrees / percent); the engine converts to RGB.
  func setHSV(h: Double, s: Double, v: Double) {
    let rgb = core.hsvToRgb([h / 360, s / 100, v / 100])
    setRGB(rgb)
  }

  /// Apply a hex string if it parses; no-op otherwise.
  func setHex(_ value: String) {
    guard let rgb = core.hexToRgb(value) else { return }
    setRGB(rgb)
  }

  // MARK: - Colour helpers (thin pass-throughs to the engine)

  /// SwiftUI `Color` for the live colour (rgb, or kelvin in white mode).
  var liveColor: Color {
    let rgb = state.mode == .rgb ? state.rgb : core.kelvinToRgb(state.temp)
    return Color(rgb: rgb)
  }

  // MARK: - Change signalling

  /// Force the status item / menu to refresh. `revision` is observed by the
  /// AppDelegate; views already react to the individual `@Published` props.
  private func bump() { revision &+= 1 }
}

// MARK: - Color convenience

extension Color {
  /// Build from a `[r,g,b]` byte triple.
  init(rgb: [Int]) {
    let r = Double(rgb.count > 0 ? rgb[0] : 0) / 255
    let g = Double(rgb.count > 1 ? rgb[1] : 0) / 255
    let b = Double(rgb.count > 2 ? rgb[2] : 0) / 255
    self.init(.sRGB, red: r, green: g, blue: b, opacity: 1)
  }
}
