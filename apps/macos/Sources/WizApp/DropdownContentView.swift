import AppKit
import Combine
import QuartzCore
import WizKit

/// A horizontal gradient-track slider, drawn and tracked in pure AppKit so it
/// works *inside a tracked NSMenu*. The trick is `mouseDown`: it runs its own
/// nested event loop pulling drag/up events straight off the window queue, so the
/// drag follows the pointer **anywhere on screen** and the mouse-up is consumed
/// here — the menu never sees an outside click, so it neither stops the drag nor
/// dismisses. (SwiftUI sliders can't do this in a menu; that's the whole reason
/// the dropdown is AppKit.)
final class GradientSliderControl: NSControl {
  var minValue: Double = 0
  var maxValue: Double = 100
  var value: Double = 0 {
    didSet { needsDisplay = true }
  }
  /// Colour stops painted left→right under the track.
  var gradientColors: [NSColor] = [.black, .white] {
    didSet { needsDisplay = true }
  }
  /// Called continuously while dragging (after `value` updates).
  var onEditing: (Double) -> Void = { _ in }
  /// Called once when the drag ends.
  var onCommit: () -> Void = {}

  /// True while a drag is in progress, so external value syncs don't fight it.
  private(set) var isTracking = false

  private let trackHeight: CGFloat = 18
  private let thumbSize: CGFloat = 16

  override var intrinsicContentSize: NSSize {
    NSSize(width: NSView.noIntrinsicMetric, height: trackHeight)
  }

  override func draw(_ dirtyRect: NSRect) {
    let b = bounds
    let track = NSRect(
      x: 0, y: (b.height - trackHeight) / 2, width: b.width, height: trackHeight)
    let radius = trackHeight / 2
    let path = NSBezierPath(roundedRect: track, xRadius: radius, yRadius: radius)

    NSGraphicsContext.current?.saveGraphicsState()
    path.addClip()
    let colors = gradientColors.count >= 2 ? gradientColors : [.black, .white]
    NSGradient(colors: colors)?.draw(in: track, angle: 0)
    NSGraphicsContext.current?.restoreGraphicsState()

    NSColor.black.withAlphaComponent(0.2).setStroke()
    path.lineWidth = 1
    path.stroke()

    // Thumb
    let usable = max(1, b.width - thumbSize)
    let frac = CGFloat((value - minValue) / max(0.0001, maxValue - minValue))
    let x = thumbSize / 2 + min(max(frac, 0), 1) * usable
    let thumbRect = NSRect(
      x: x - thumbSize / 2, y: (b.height - thumbSize) / 2, width: thumbSize, height: thumbSize)
    let thumb = NSBezierPath(ovalIn: thumbRect)
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.4)
    shadow.shadowBlurRadius = 2
    shadow.shadowOffset = NSSize(width: 0, height: -1)
    NSGraphicsContext.current?.saveGraphicsState()
    shadow.set()
    NSColor.white.setFill()
    thumb.fill()
    NSGraphicsContext.current?.restoreGraphicsState()
    NSColor.black.withAlphaComponent(0.55).setStroke()
    thumb.lineWidth = 1.5
    thumb.stroke()
  }

  override func mouseDown(with event: NSEvent) {
    guard isEnabled, let window = window else { return }
    isTracking = true
    setValue(from: event)
    onEditing(value)
    while true {
      guard
        let next = window.nextEvent(matching: [.leftMouseUp, .leftMouseDragged])
      else { break }
      if next.type == .leftMouseUp { break }
      setValue(from: next)
      onEditing(value)
    }
    isTracking = false
    onCommit()
  }

  private func setValue(from event: NSEvent) {
    let p = convert(event.locationInWindow, from: nil)
    let usable = max(1, bounds.width - thumbSize)
    let x = min(max(p.x - thumbSize / 2, 0), usable)
    let frac = Double(x / usable)
    value = minValue + frac * (maxValue - minValue)
  }
}

/// A switch drawn entirely by us. A stock `NSSwitch` inside a menu renders in the
/// *inactive* appearance and never shows the accent colour (the controls in a
/// menu aren't in a key window) — so the on/off state had no colour. Drawing it
/// ourselves lets the track be accent-on / grey-off regardless. The mouse-up is
/// consumed so a tap doesn't dismiss the tracked menu.
final class ToggleSwitchControl: NSControl {
  private(set) var isOn = false
  var onToggle: (Bool) -> Void = { _ in }

  /// Set the on/off state. `animated` is true only for a user tap — programmatic
  /// updates (a menu rebuild on mode switch, or state sync) pass false, so the knob
  /// doesn't spuriously slide (from a not-yet-laid-out position) when the dropdown
  /// rebuilds. No-ops if the value is unchanged, so a post-tap sync can't cut the
  /// tap's animation short.
  func setOn(_ on: Bool, animated: Bool) {
    guard isOn != on else { return }
    isOn = on
    updateLayers(animated: animated)
  }

  private let switchWidth: CGFloat = 46
  private let switchHeight: CGFloat = 22
  private let inset: CGFloat = 3
  private let trackLayer = CALayer()
  private let knobLayer = CALayer()

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
    trackLayer.cornerRadius = switchHeight / 2
    knobLayer.backgroundColor = NSColor.white.cgColor
    knobLayer.shadowColor = NSColor.black.cgColor
    knobLayer.shadowOpacity = 0.3
    knobLayer.shadowRadius = 1.5
    knobLayer.shadowOffset = CGSize(width: 0, height: -1)
    layer?.addSublayer(trackLayer)
    layer?.addSublayer(knobLayer)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError() }

  override var intrinsicContentSize: NSSize { NSSize(width: switchWidth, height: switchHeight) }

  private var trackRect: NSRect {
    NSRect(x: 0, y: (bounds.height - switchHeight) / 2, width: switchWidth, height: switchHeight)
  }
  private var knobSize: NSSize {
    let h = switchHeight - inset * 2
    return NSSize(width: h + 3, height: h)  // slightly oval — wider than tall
  }
  private func knobCenter() -> CGPoint {
    let t = trackRect
    let w = knobSize.width
    return CGPoint(x: isOn ? t.maxX - inset - w / 2 : t.minX + inset + w / 2, y: t.midY)
  }

  override func layout() {
    super.layout()
    updateLayers(animated: false)  // only toggles animate, not layout passes
  }

  /// Move the knob and tint the track. When animated, drive it with explicit CA
  /// animations (from the current presentation value) so the slide runs smoothly
  /// even while the menu's modal event loop owns the main run loop.
  private func updateLayers(animated: Bool) {
    let color = (isOn ? NSColor.controlAccentColor : NSColor.tertiaryLabelColor).cgColor
    let center = knobCenter()
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    trackLayer.frame = trackRect
    trackLayer.cornerRadius = switchHeight / 2
    knobLayer.bounds = CGRect(origin: .zero, size: knobSize)
    knobLayer.cornerRadius = knobSize.height / 2
    if animated {
      let move = CABasicAnimation(keyPath: "position")
      move.fromValue = knobLayer.presentation()?.position ?? knobLayer.position
      move.toValue = center
      move.duration = 0.18
      move.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
      knobLayer.add(move, forKey: "position")
      let tint = CABasicAnimation(keyPath: "backgroundColor")
      tint.fromValue = trackLayer.presentation()?.backgroundColor ?? trackLayer.backgroundColor
      tint.toValue = color
      tint.duration = 0.18
      trackLayer.add(tint, forKey: "backgroundColor")
    }
    knobLayer.position = center
    trackLayer.backgroundColor = color
    CATransaction.commit()
  }

  override func mouseDown(with event: NSEvent) {
    guard isEnabled, let window = window else { return }
    setOn(!isOn, animated: true)
    onToggle(isOn)
    // Consume the mouse-up so the tracked menu doesn't treat the tap as a
    // selection and dismiss.
    _ = window.nextEvent(matching: [.leftMouseUp])
  }
}

/// A small round icon button drawn by us, so the background highlight is always a
/// true circle — a bordered NSButton imposes a minimum width, which made the
/// highlight an oval. Acts on mouse-down and consumes the mouse-up so a tap
/// doesn't dismiss the tracked menu.
final class CircleIconButton: NSControl {
  private let onClick: () -> Void
  private let diameter: CGFloat = 20

  init(symbol: String, tooltip: String, onClick: @escaping () -> Void) {
    self.onClick = onClick
    super.init(frame: NSRect(x: 0, y: 0, width: diameter, height: diameter))
    toolTip = tooltip
    wantsLayer = true
    let icon = NSImageView()
    icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)?
      .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold))
    icon.contentTintColor = .labelColor
    icon.translatesAutoresizingMaskIntoConstraints = false
    addSubview(icon)
    NSLayoutConstraint.activate([
      icon.centerXAnchor.constraint(equalTo: centerXAnchor),
      icon.centerYAnchor.constraint(equalTo: centerYAnchor),
    ])
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError() }

  override var intrinsicContentSize: NSSize { NSSize(width: diameter, height: diameter) }

  override func draw(_ dirtyRect: NSRect) {
    NSColor.secondaryLabelColor.withAlphaComponent(0.15).setFill()
    NSBezierPath(ovalIn: bounds).fill()
  }

  override func mouseDown(with event: NSEvent) {
    guard isEnabled, let window = window else { return }
    onClick()
    _ = window.nextEvent(matching: [.leftMouseUp])
  }
}

/// The menu-bar dropdown's content, in pure AppKit so it can live inside a tracked
/// `NSMenu` (the only thing that keeps the macOS menu bar revealed over a
/// full-screen Space). Mirrors the SwiftUI `DropdownView`: header, power switch,
/// RGB/White/Warm-Glow picker, brightness + colour/temperature gradient sliders,
/// and the disconnected / first-install states. Reads and drives the shared
/// `AppState`, rebuilding when the structure changes and syncing values otherwise.
@MainActor
final class DropdownContentView: NSView {
  private let app: AppState
  private let onOpenControls: () -> Void
  private let onQuit: () -> Void

  private let stack = NSStackView()
  private var cancellables: Set<AnyCancellable> = []
  private var structureKey = ""
  private var syncScheduled = false

  // Persistent controls updated in-place during value syncs.
  private var nameLabel: NSTextField?
  private var powerSwitch: ToggleSwitchControl?
  private var modeControl: NSSegmentedControl?
  private var brightnessSlider: GradientSliderControl?
  private var colorSlider: GradientSliderControl?

  private static let contentWidth: CGFloat = 262  // 290 panel − 14pt insets each side

  init(app: AppState, onOpenControls: @escaping () -> Void, onQuit: @escaping () -> Void) {
    self.app = app
    self.onOpenControls = onOpenControls
    self.onQuit = onQuit
    super.init(frame: NSRect(x: 0, y: 0, width: 290, height: 200))

    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 12
    stack.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
    stack.translatesAutoresizingMaskIntoConstraints = false
    addSubview(stack)
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: leadingAnchor),
      stack.trailingAnchor.constraint(equalTo: trailingAnchor),
      stack.topAnchor.constraint(equalTo: topAnchor),
      stack.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])

    rebuild()

    app.objectWillChange
      .sink { [weak self] _ in self?.scheduleSync() }
      .store(in: &cancellables)
    UpdateChecker.shared.objectWillChange
      .sink { [weak self] _ in self?.scheduleSync() }
      .store(in: &cancellables)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError() }

  // MARK: - Structure

  /// A signature of everything that changes the *layout* (vs. just values), so we
  /// only tear down and rebuild when the shape actually changes.
  private func currentStructureKey() -> String {
    let update = UpdateChecker.shared.updateAvailable && UpdateChecker.shared.latestVersion != nil
    return "\(app.connected)|\(app.hasLight)|\(app.colorMode.rawValue)|\(update)"
  }

  private func scheduleSync() {
    guard !syncScheduled else { return }
    syncScheduled = true
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      self.syncScheduled = false
      if self.currentStructureKey() != self.structureKey {
        self.rebuild()
      } else {
        self.syncValues()
      }
    }
  }

  private func rebuild() {
    structureKey = currentStructureKey()
    for v in stack.arrangedSubviews { stack.removeArrangedSubview(v); v.removeFromSuperview() }
    nameLabel = nil
    powerSwitch = nil
    modeControl = nil
    brightnessSlider = nil
    colorSlider = nil

    if UpdateChecker.shared.updateAvailable, let latest = UpdateChecker.shared.latestVersion {
      stack.addArrangedSubview(makeUpdateRow(latest))
    }
    stack.addArrangedSubview(makeHeader())
    stack.addArrangedSubview(makeDivider())

    if app.connected {
      stack.addArrangedSubview(makeControlsRow())
      stack.addArrangedSubview(makeBrightnessRow())
      if !app.warmGlow {
        stack.addArrangedSubview(makeColorRow())
      }
    } else {
      stack.addArrangedSubview(makeDisconnected())
    }
    syncValues()
    updateFrameToFit()
  }

  /// Resize the view to fit its current content at the fixed 290-pt width, so the
  /// menu measures the right size — including shrinking when Warm Glow drops the
  /// colour row. Width is pinned (not taken from `fittingSize`) because AppKit
  /// controls report their width lazily, which made the first open render too
  /// narrow (the rows overflowed to the edge).
  func updateFrameToFit() {
    setFrameSize(NSSize(width: 290, height: max(1, fittingSize.height)))
    layoutSubtreeIfNeeded()
    setFrameSize(NSSize(width: 290, height: max(1, fittingSize.height)))
    // Nudge the open menu to re-measure this item so it grows/shrinks with the
    // content (e.g. Warm Glow dropping the colour row).
    invalidateIntrinsicContentSize()
  }

  /// Update live values in place without rebuilding (skipping a slider mid-drag).
  private func syncValues() {
    nameLabel?.stringValue = headerText
    if let mode = modeControl,
      let idx = AppState.ColorMode.popoverModes.firstIndex(of: app.colorMode)
    {
      mode.selectedSegment = idx
    }
    // Animate power changes that happen while the dropdown is open (e.g. dragging
    // brightness to 0 turns the light off, or up from 0 turns it on) so the knob
    // slides instead of jumping. Rebuilds still snap: makeControlsRow sets the fresh
    // toggle non-animated and this then no-ops (setOn ignores an unchanged value).
    powerSwitch?.setOn(app.state.on, animated: true)
    if let bright = brightnessSlider, !bright.isTracking {
      bright.value = app.state.on ? Double(app.state.brightness) : 0
    }
    brightnessSlider?.gradientColors = [Self.nsColor([43, 43, 43]), liveNSColor]
    if let color = colorSlider, !color.isTracking {
      color.value = app.state.mode == .rgb ? app.hsv.h : Double(app.state.temp)
      color.gradientColors = app.state.mode == .rgb ? hueStops() : tempStops()
    }
  }

  // MARK: - Rows

  private func fullWidth(_ view: NSView) -> NSView {
    view.translatesAutoresizingMaskIntoConstraints = false
    view.widthAnchor.constraint(equalToConstant: Self.contentWidth).isActive = true
    return view
  }

  private func makeHeader() -> NSView {
    let row = NSStackView()
    row.orientation = .horizontal
    row.spacing = 8
    row.alignment = .centerY

    let icon = NSImageView()
    icon.image = Self.appIcon
    icon.translatesAutoresizingMaskIntoConstraints = false
    icon.widthAnchor.constraint(equalToConstant: 18).isActive = true
    icon.heightAnchor.constraint(equalToConstant: 18).isActive = true

    let label = NSTextField(labelWithString: headerText)
    label.font = .systemFont(ofSize: 11, weight: .semibold)
    label.lineBreakMode = .byTruncatingTail
    label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    nameLabel = label

    let controls = CircleIconButton(symbol: "slider.horizontal.3", tooltip: "Open the controls window") {
      [weak self] in self?.onOpenControls()
    }
    let quit = CircleIconButton(symbol: "xmark", tooltip: "Quit WiZ Light Controller") {
      [weak self] in self?.onQuit()
    }

    row.addArrangedSubview(icon)
    row.addArrangedSubview(label)
    row.addArrangedSubview(NSView())  // spacer
    row.addArrangedSubview(controls)
    row.addArrangedSubview(quit)
    return fullWidth(row)
  }

  private func makeDivider() -> NSView {
    let box = NSBox()
    box.boxType = .separator
    return fullWidth(box)
  }

  private func makeControlsRow() -> NSView {
    let row = NSStackView()
    row.orientation = .horizontal
    row.spacing = 16  // a touch more gap between the switch and the mode picker
    row.alignment = .centerY
    row.distribution = .fill

    let sw = ToggleSwitchControl()
    sw.setOn(app.state.on, animated: false)
    sw.onToggle = { [weak self] on in self?.app.setPower(on) }
    sw.setContentHuggingPriority(.required, for: .horizontal)
    sw.setContentCompressionResistancePriority(.required, for: .horizontal)
    powerSwitch = sw

    let mode = NSSegmentedControl(
      labels: AppState.ColorMode.popoverModes.map(\.label),
      trackingMode: .selectOne, target: self, action: #selector(modeChanged(_:)))
    if let idx = AppState.ColorMode.popoverModes.firstIndex(of: app.colorMode) {
      mode.selectedSegment = idx
    }
    mode.segmentDistribution = .fillEqually
    mode.setContentHuggingPriority(.defaultLow, for: .horizontal)
    modeControl = mode

    row.addArrangedSubview(sw)
    row.addArrangedSubview(mode)
    return fullWidth(row)
  }

  private func makeBrightnessRow() -> NSView {
    let slider = GradientSliderControl()
    slider.minValue = 0
    slider.maxValue = 100
    slider.value = app.state.on ? Double(app.state.brightness) : 0
    slider.gradientColors = [Self.nsColor([43, 43, 43]), liveNSColor]
    slider.onEditing = { [weak self] v in self?.app.setBrightnessLevel(Int(v.rounded())) }
    slider.onCommit = { [weak self] in self?.app.commitBrightnessMemory() }
    brightnessSlider = slider
    return sliderRow("sun.max", slider)
  }

  private func makeColorRow() -> NSView {
    let slider = GradientSliderControl()
    colorSlider = slider
    if app.state.mode == .rgb {
      slider.minValue = 0
      slider.maxValue = 359
      slider.value = app.hsv.h
      slider.gradientColors = hueStops()
      slider.onEditing = { [weak self] v in
        guard let self else { return }
        self.app.setHSV(h: v, s: self.app.hsv.s < 1 ? 100 : self.app.hsv.s, v: max(1, self.app.hsv.v))
      }
      return sliderRow("paintpalette", slider)
    } else {
      slider.minValue = Double(app.tempRange.lowerBound)
      slider.maxValue = Double(app.tempRange.upperBound)
      slider.value = Double(app.state.temp)
      slider.gradientColors = tempStops()
      slider.onEditing = { [weak self] v in
        guard let self else { return }
        self.app.state.temp = self.app.clampTemp(Int((v / 100).rounded()) * 100)
        self.app.state.mode = .white
        self.app.applyLive()
      }
      return sliderRow("thermometer.medium", slider)
    }
  }

  private func sliderRow(_ symbol: String, _ slider: GradientSliderControl) -> NSView {
    let row = NSStackView()
    row.orientation = .horizontal
    row.spacing = 10
    row.alignment = .centerY

    let icon = NSImageView()
    icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
    icon.contentTintColor = .secondaryLabelColor
    icon.translatesAutoresizingMaskIntoConstraints = false
    icon.widthAnchor.constraint(equalToConstant: 18).isActive = true

    slider.translatesAutoresizingMaskIntoConstraints = false
    slider.setContentHuggingPriority(.defaultLow, for: .horizontal)

    row.addArrangedSubview(icon)
    row.addArrangedSubview(slider)
    return fullWidth(row)
  }

  private func makeDisconnected() -> NSView {
    let col = NSStackView()
    col.orientation = .vertical
    col.alignment = .leading
    col.spacing = 8

    if app.hasLight {
      let button = NSButton(
        title: "Connect to \(app.displayName)", target: self, action: #selector(connect))
      button.bezelStyle = .rounded
      button.controlSize = .large
      col.addArrangedSubview(fullWidth(button))
    } else {
      let title = NSTextField(labelWithString: "No lights set up yet")
      title.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
      let caption = NSTextField(
        wrappingLabelWithString: "Scan your network for WiZ lights, then save one to control it here.")
      caption.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
      caption.textColor = .secondaryLabelColor
      caption.preferredMaxLayoutWidth = Self.contentWidth  // deterministic wrap height
      let button = NSButton(title: "Discover lights…", target: self, action: #selector(discover))
      button.bezelStyle = .rounded
      button.controlSize = .large
      col.addArrangedSubview(title)
      col.addArrangedSubview(fullWidth(caption))
      col.addArrangedSubview(fullWidth(button))
    }
    return fullWidth(col)
  }

  private func makeUpdateRow(_ latest: String) -> NSView {
    let button = NSButton(
      title: "Update available: v\(latest)", target: self, action: #selector(openUpdate))
    button.bezelStyle = .inline
    button.isBordered = false
    button.contentTintColor = .secondaryLabelColor
    button.image = NSImage(systemSymbolName: "arrow.down.circle.fill", accessibilityDescription: nil)
    button.imagePosition = .imageLeading
    return fullWidth(button)
  }

  // MARK: - Actions

  @objc private func modeChanged(_ sender: NSSegmentedControl) {
    let modes = AppState.ColorMode.popoverModes
    guard sender.selectedSegment >= 0, sender.selectedSegment < modes.count else { return }
    app.setColorMode(modes[sender.selectedSegment])
  }
  @objc private func connect() { app.reconnect() }
  @objc private func discover() {
    app.requestDiscovery = true
    onOpenControls()
  }
  @objc private func openUpdate() {
    if let url = UpdateChecker.shared.releasePageURL { NSWorkspace.shared.open(url) }
  }

  // MARK: - Derived values

  private var headerText: String {
    if app.connected { return "Device: \(app.displayName)" }
    if app.hasLight { return "Not connected" }
    return "No light selected"
  }

  private var liveNSColor: NSColor {
    let rgb = app.state.mode == .rgb ? app.state.rgb : app.core.kelvinToRgb(app.state.temp)
    return Self.nsColor(rgb)
  }

  private func hueStops() -> [NSColor] {
    stride(from: 0.0, through: 360.0, by: 60.0).map { Self.nsColor(app.core.hsvToRgb([$0 / 360, 1, 1])) }
  }

  private func tempStops() -> [NSColor] {
    let lo = app.tempRange.lowerBound
    let hi = app.tempRange.upperBound
    return stride(from: 0.0, through: 1.0, by: 0.25).map {
      Self.nsColor(app.core.kelvinToRgb(Int(Double(lo) + $0 * Double(hi - lo))))
    }
  }

  private static func nsColor(_ rgb: [Int]) -> NSColor {
    NSColor(
      srgbRed: CGFloat(rgb.count > 0 ? rgb[0] : 0) / 255,
      green: CGFloat(rgb.count > 1 ? rgb[1] : 0) / 255,
      blue: CGFloat(rgb.count > 2 ? rgb[2] : 0) / 255,
      alpha: 1)
  }

  private static let appIcon: NSImage = {
    if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
      let img = NSImage(contentsOf: url)
    {
      return img
    }
    return NSApplication.shared.applicationIconImage
  }()
}
