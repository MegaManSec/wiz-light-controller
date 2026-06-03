import AppKit
import WizKit

/// Builds the status-item `NSMenu`. Mirrors blue-switch's MenuBarView: an
/// optional "Update Available" item at the top, a section header naming the
/// active light, power toggle + brightness submenu, a saved-lights section,
/// then the window/sync/settings/quit actions — all with SF-Symbol images,
/// tooltips, and key equivalents. Items target `AppDelegate`.
@MainActor
final class MenuBarController {
  private let appState: AppState
  private weak var delegate: AppDelegate?
  /// The live brightness slider in the open menu, so colour edits can re-tint it.
  private weak var brightnessSlider: MenuSlider?

  private enum Symbols {
    static let update = "arrow.down.circle.fill"
    static let on = "lightbulb.fill"
    static let off = "lightbulb"
    static let brightness = "sun.max"
    static let light = "lightbulb"
    static let window = "slider.horizontal.3"
    static let quit = "power"
  }

  init(appState: AppState, delegate: AppDelegate) {
    self.appState = appState
    self.delegate = delegate
  }

  /// Fresh menu each open so it reflects current state.
  func makeMenu() -> NSMenu {
    let menu = NSMenu()
    menu.autoenablesItems = false

    addUpdateItem(to: menu)
    addLightHeader(to: menu)
    // Live light controls only make sense once we've reached the bulb.
    if appState.connected {
      addPowerItem(to: menu)
      if appState.state.on {
        addBrightnessSlider(to: menu)
        if !appState.warmGlow { addColorSlider(to: menu) }
      }
    }
    addSavedLights(to: menu)

    menu.addItem(.separator())
    // One entry opens the window — which already has both Controls and Settings.
    menu.addItem(
      item(
        "Open WiZ Light Controller…", symbol: Symbols.window,
        action: #selector(AppDelegate.openControllerFromMenu(_:)),
        tooltip: "Open the full controls and settings window."))

    menu.addItem(.separator())
    menu.addItem(
      item(
        "Quit WiZ Light Controller", symbol: Symbols.quit,
        action: #selector(AppDelegate.quitFromStatusBar(_:)), key: "q"))

    return menu
  }

  // MARK: - Sections

  /// Surface an available update at the very top — clicking opens the release
  /// page. Nothing destructive, so it stays enabled.
  private func addUpdateItem(to menu: NSMenu) {
    let checker = UpdateChecker.shared
    guard checker.updateAvailable, let latest = checker.latestVersion else { return }
    let it = item(
      "Update Available: v\(latest)", symbol: Symbols.update,
      action: #selector(AppDelegate.openLatestReleasePage(_:)),
      tooltip: "A newer version is available. Opens the release page.")
    menu.addItem(it)
    menu.addItem(.separator())
  }

  private func lightHeaderTitle() -> String {
    guard appState.hasLight else { return "No light selected" }
    let name = appState.displayName
    // Don't repeat the address as "IP — IP" when we have nothing better than it.
    return name == appState.selectedIp ? name : "\(name) — \(appState.selectedIp)"
  }

  private func addLightHeader(to menu: NSMenu) {
    menu.addItem(sectionHeader(lightHeaderTitle()))
  }

  /// Single power toggle: a checkmark means the light is on; clicking flips it.
  private func addPowerItem(to menu: NSMenu) {
    let on = appState.state.on
    let it = item(
      "Power", symbol: on ? Symbols.on : Symbols.off,
      action: #selector(AppDelegate.togglePower(_:)),
      tooltip: on ? "Turn the light off." : "Turn the light on.")
    it.state = on ? .on : .off
    menu.addItem(it)
  }

  /// A live brightness slider whose track ramps from dark to the colour the bulb
  /// will actually show.
  private func addBrightnessSlider(to menu: NSMenu) {
    let colour = currentColourRgb()
    let (item, slider) = sliderRow(
      symbol: Symbols.brightness, min: 1, max: 100, value: Double(appState.state.brightness),
      gradient: gradient(from: scaled(colour, 0.12), to: colour), iconXOffset: -3
    ) { [weak self] value in
      guard let self else { return }
      self.appState.setBrightness(Int(value.rounded()))
      self.appState.applyLive()
      self.refreshBrightnessGradient()  // Warm Glow shifts colour with brightness
    }
    brightnessSlider = slider
    menu.addItem(item)
  }

  /// A live colour slider: a hue rainbow in RGB mode, a warm→cool ramp in white.
  private func addColorSlider(to menu: NSMenu) {
    if appState.state.mode == .rgb {
      let (item, _) = sliderRow(
        symbol: "paintpalette", min: 0, max: 360, value: appState.hsv.h, gradient: hueGradient()
      ) { [weak self] value in
        guard let self else { return }
        let hsv = self.appState.hsv
        self.appState.setHSV(h: value, s: hsv.s, v: Swift.max(1, hsv.v))
        self.refreshBrightnessGradient()
      }
      menu.addItem(item)
    } else {
      let (item, _) = sliderRow(
        symbol: "thermometer.medium", min: Double(appState.tempRange.lowerBound),
        max: Double(appState.tempRange.upperBound), value: Double(appState.state.temp),
        gradient: tempGradient()
      ) { [weak self] value in
        guard let self else { return }
        self.appState.state.temp = self.appState.clampTemp(Int(value.rounded()))
        self.appState.state.mode = .white
        self.appState.applyLive()
        self.refreshBrightnessGradient()
      }
      menu.addItem(item)
    }
  }

  /// Build a menu row: a leading icon + a full-width gradient `MenuSlider`. The
  /// row is sized to the menu's content width so the slider spans it.
  private func sliderRow(
    symbol: String, min: Double, max: Double, value: Double, gradient: NSGradient,
    iconXOffset: CGFloat = 0,
    onChange: @escaping (Double) -> Void
  ) -> (item: NSMenuItem, slider: MenuSlider) {
    let width = menuWidth()
    let height: CGFloat = 26
    let container = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))

    // x lines the icon up with the standard items' image column (right of the
    // reserved checkmark/state column), matching the Power + saved-light icons.
    // iconXOffset trims a symbol's own left whitespace so different SF Symbols'
    // visible edges line up (sun.max renders a few pt right of thermometer.medium).
    let icon = NSImageView(
      frame: NSRect(x: 26 + iconXOffset, y: (height - 15) / 2, width: 15, height: 15))
    icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
    icon.imageAlignment = .alignLeft // pin the symbol's left edge to x, not a centered inset
    icon.contentTintColor = .secondaryLabelColor
    container.addSubview(icon)

    let sliderX: CGFloat = 52 // track start, kept clear of the icon column
    let slider = MenuSlider(frame: NSRect(x: sliderX, y: 0, width: width - sliderX - 16, height: height))
    slider.minValue = min
    slider.maxValue = max
    slider.value = value
    slider.gradient = gradient
    slider.onChange = onChange
    container.addSubview(slider)

    let row = NSMenuItem()
    row.view = container
    return (row, slider)
  }

  // MARK: - Menu sizing + gradients

  /// Width that fits the widest text row, so the slider rows span the full menu
  /// instead of stopping short.
  private func menuWidth() -> CGFloat {
    let font = NSFont.menuFont(ofSize: 0)
    let titles = [
      lightHeaderTitle(), "Open WiZ Light Controller…", "Sync from Light",
      "Quit WiZ Light Controller",
    ]
    let widest = titles.map { ($0 as NSString).size(withAttributes: [.font: font]).width }.max() ?? 220
    return Swift.min(Swift.max(widest + 80, 280), 460)
  }

  /// The colour the bulb is currently showing (RGB, or the kelvin tint in white).
  private func currentColourRgb() -> [Int] {
    appState.state.mode == .rgb ? appState.state.rgb : appState.core.kelvinToRgb(appState.state.temp)
  }

  /// Re-tint the brightness track to the live colour while the menu is open (its
  /// gradient is built once, so colour / temperature edits must refresh it).
  private func refreshBrightnessGradient() {
    let colour = currentColourRgb()
    brightnessSlider?.gradient = gradient(from: scaled(colour, 0.12), to: colour)
    brightnessSlider?.needsDisplay = true
  }

  private func nsColor(_ rgb: [Int]) -> NSColor {
    NSColor(
      srgbRed: CGFloat(rgb[0]) / 255, green: CGFloat(rgb[1]) / 255, blue: CGFloat(rgb[2]) / 255,
      alpha: 1)
  }

  private func scaled(_ rgb: [Int], _ factor: Double) -> [Int] {
    rgb.map { Int((Double($0) * factor).rounded()) }
  }

  private func gradient(from: [Int], to: [Int]) -> NSGradient {
    NSGradient(starting: nsColor(from), ending: nsColor(to)) ?? NSGradient(colors: [nsColor(to)])!
  }

  private func hueGradient() -> NSGradient {
    let stops = stride(from: 0.0, through: 1.0, by: 1.0 / 12).map {
      nsColor(appState.core.hsvToRgb([$0, 1, 1]))
    }
    return NSGradient(colors: stops) ?? NSGradient(colors: [.white])!
  }

  private func tempGradient() -> NSGradient {
    let lo = appState.tempRange.lowerBound
    let hi = appState.tempRange.upperBound
    let stops = stride(from: 0.0, through: 1.0, by: 0.25).map { t in
      nsColor(appState.core.kelvinToRgb(Int(Double(lo) + t * Double(hi - lo))))
    }
    return NSGradient(colors: stops) ?? NSGradient(colors: [.white])!
  }

  /// One row per saved light; clicking selects it, a checkmark marks the active.
  private func addSavedLights(to menu: NSMenu) {
    guard !appState.savedLights.isEmpty else { return }
    menu.addItem(.separator())
    menu.addItem(sectionHeader("Saved Lights"))
    let sorted = appState.savedLights.sorted { $0.value.name < $1.value.name }
    for (mac, light) in sorted {
      let isActive = mac == appState.selectedMac && appState.connected
      let it = item(
        light.name, symbol: Symbols.light,
        action: #selector(AppDelegate.selectSavedLight(_:)),
        tooltip: isActive
          ? "Disconnect from \(light.name)."
          : "Connect to \(light.name) (\(light.ip)).")
      it.representedObject = mac
      it.state = isActive ? .on : .off
      menu.addItem(it)
    }
  }

  // MARK: - Item factory

  private func item(
    _ title: String, symbol: String, action: Selector?, key: String = "", tooltip: String? = nil
  ) -> NSMenuItem {
    let it = NSMenuItem(title: title, action: action, keyEquivalent: key)
    it.target = delegate
    if let img = NSImage(systemSymbolName: symbol, accessibilityDescription: title) {
      it.image = img
    }
    it.toolTip = tooltip
    return it
  }

  /// Native section header on macOS 14+, a styled disabled item on 13 (we deploy
  /// to 13).
  private func sectionHeader(_ title: String) -> NSMenuItem {
    if #available(macOS 14.0, *) {
      return NSMenuItem.sectionHeader(title: title)
    }
    let it = NSMenuItem(title: title, action: nil, keyEquivalent: "")
    it.attributedTitle = NSAttributedString(
      string: title,
      attributes: [
        .font: NSFont.boldSystemFont(ofSize: NSFont.smallSystemFontSize),
        .foregroundColor: NSColor.secondaryLabelColor,
      ])
    it.isEnabled = false
    return it
  }
}
