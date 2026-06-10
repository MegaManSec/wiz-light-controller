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
  /// When set, draw a solid progress track — `filled` left of the thumb, `unfilled`
  /// after it — instead of the gradient. Used by the scene-speed slider.
  var progressFill: (filled: NSColor, unfilled: NSColor)? {
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
    if let pf = progressFill {
      let frac = CGFloat((value - minValue) / max(0.0001, maxValue - minValue))
      let fillW = thumbSize / 2 + min(max(frac, 0), 1) * max(1, b.width - thumbSize)  // to thumb centre
      pf.unfilled.setFill()
      NSBezierPath(rect: track).fill()
      pf.filled.setFill()
      NSBezierPath(rect: NSRect(x: track.minX, y: track.minY, width: fillW, height: track.height)).fill()
    } else {
      let colors = gradientColors.count >= 2 ? gradientColors : [.black, .white]
      NSGradient(colors: colors)?.draw(in: track, angle: 0)
    }
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

/// A transparent clickable container for the tracked menu: routes clicks anywhere
/// in its frame to `onClick` (ignoring the visual subviews) and consumes the
/// mouse-up so a tap doesn't dismiss the menu. Used for the scene header + chips.
final class TapControl: NSControl {
  private let onClick: () -> Void
  init(onClick: @escaping () -> Void) {
    self.onClick = onClick
    super.init(frame: .zero)
    wantsLayer = true
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError() }

  override func hitTest(_ point: NSPoint) -> NSView? {
    bounds.contains(convert(point, from: superview)) ? self : nil
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
  private var speedSlider: GradientSliderControl?
  private var sceneHeaderLabel: NSTextField?
  private var sceneListExpanded = false
  // Row containers, so a hover hint covers the whole row (icon + slider), not just the slider.
  private var brightnessRow: NSView?
  private var colorRow: NSView?
  private var speedRow: NSView?

  /// Popover modes — adds Scenes only when the bulb supports them (gated like the
  /// controls window). Scenes live only in the controls window otherwise.
  private var popoverModes: [AppState.ColorMode] {
    app.supportsScenes ? AppState.ColorMode.popoverModes + [.scene] : AppState.ColorMode.popoverModes
  }

  private static let panelWidth: CGFloat = 356  // fits switch + 4 full mode segments (incl. "Warm Glow") + insets
  private static let contentWidth: CGFloat = panelWidth - 28  // 14pt insets each side

  init(app: AppState, onOpenControls: @escaping () -> Void, onQuit: @escaping () -> Void) {
    self.app = app
    self.onOpenControls = onOpenControls
    self.onQuit = onQuit
    super.init(frame: NSRect(x: 0, y: 0, width: Self.panelWidth, height: 200))

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
    return "\(statusPhaseKey)|\(app.hasLight)|\(app.colorMode.rawValue)|\(app.supportsScenes)|\(sceneListExpanded)|\(app.state.scene?.id ?? 0)|\(update)"
  }

  /// Coarse connection phase for the structure key: the disconnected panel renders
  /// differently per phase (spinner / error message / Connect button), so a phase
  /// change must rebuild it. The error *text* is deliberately excluded — it's read
  /// live in `makeDisconnected`, so only real phase flips trigger a rebuild.
  private var statusPhaseKey: String {
    switch app.status {
    case .noLight: return "noLight"
    case .connecting: return "connecting"
    case .connected: return "connected"
    case .disconnected: return "disconnected"
    case .error: return "error"
    }
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
    speedSlider = nil
    sceneHeaderLabel = nil
    brightnessRow = nil
    colorRow = nil
    speedRow = nil

    if UpdateChecker.shared.updateAvailable, let latest = UpdateChecker.shared.latestVersion {
      stack.addArrangedSubview(makeUpdateRow(latest))
    }
    stack.addArrangedSubview(makeHeader())
    stack.addArrangedSubview(makeDivider())

    if app.connected {
      stack.addArrangedSubview(makeControlsRow())
      if app.colorMode == .scene {
        stack.addArrangedSubview(makeBrightnessRow())
        stack.addArrangedSubview(makeSpeedRow())
        // Scene selector sits at the bottom; expanding it grows the menu downward.
        stack.addArrangedSubview(makeSceneHeaderRow())
        if sceneListExpanded {
          stack.addArrangedSubview(makeSceneGrid())
        }
      } else {
        stack.addArrangedSubview(makeBrightnessRow())
        // Warm Glow's temperature is automatic, so it shows brightness only (the
        // colour/temperature row fades out, and the menu shrinks to fit).
        if !app.warmGlow {
          stack.addArrangedSubview(makeColorRow())
        }
      }
    } else {
      stack.addArrangedSubview(makeDisconnected())
    }
    syncValues()
    updateFrameToFit()
  }

  /// Resize the view to fit its current content at the fixed panel width, so the
  /// menu measures the right size — including shrinking when Warm Glow drops the
  /// colour row. Width is pinned (not taken from `fittingSize`) because AppKit
  /// controls report their width lazily, which made the first open render too
  /// narrow (the rows overflowed to the edge).
  func updateFrameToFit() {
    setFrameSize(NSSize(width: Self.panelWidth, height: max(1, fittingSize.height)))
    layoutSubtreeIfNeeded()
    setFrameSize(NSSize(width: Self.panelWidth, height: max(1, fittingSize.height)))
    // Nudge the open menu to re-measure this item so it grows/shrinks with the
    // content (e.g. Warm Glow dropping the colour row).
    invalidateIntrinsicContentSize()
  }

  /// Update live values in place without rebuilding (skipping a slider mid-drag).
  private func syncValues() {
    nameLabel?.stringValue = headerText
    if let mode = modeControl, let idx = popoverModes.firstIndex(of: app.colorMode) {
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
    if let speed = speedSlider, !speed.isTracking {
      speed.value = Double(app.state.scene?.speed ?? 100)
    }
    sceneHeaderLabel?.stringValue =
      app.availableScenes.first { $0.id == app.state.scene?.id }?.name ?? "Choose a scene"

    // Hover hints: what each control does + its current value, on the whole row
    // (icon + slider) and on the switch / mode picker / device name.
    let brightnessTip = app.state.on ? "Brightness — \(app.state.brightness)%" : "Brightness — off"
    brightnessRow?.toolTip = brightnessTip
    brightnessSlider?.toolTip = brightnessTip
    let colorTip =
      app.state.mode == .rgb
      ? "Colour (hue) — \(Int(app.hsv.h))°" : "Colour temperature — \(app.state.temp) K"
    colorRow?.toolTip = colorTip
    colorSlider?.toolTip = colorTip
    let speedTip = "Scene speed — \(app.state.scene?.speed ?? 100)%"
    speedRow?.toolTip = speedTip
    speedSlider?.toolTip = speedTip
    powerSwitch?.toolTip = app.state.on ? "On — tap to turn off" : "Off — tap to turn on"
    nameLabel?.toolTip = deviceTooltip
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
      labels: popoverModes.map(\.label),
      trackingMode: .selectOne, target: self, action: #selector(modeChanged(_:)))
    if let idx = popoverModes.firstIndex(of: app.colorMode) {
      mode.selectedSegment = idx
    }
    for (i, m) in popoverModes.enumerated() { mode.setToolTip(modeTooltip(m), forSegment: i) }
    // Proportional (not equal) so long labels — "Warm Glow", "Scenes" — keep their
    // full width instead of truncating to fit an equal share.
    mode.segmentDistribution = .fillProportionally
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
    slider.onEditing = { [weak self] v in
      self?.app.isDraggingBrightness = true
      self?.app.setBrightnessLevel(Int(v.rounded()))
    }
    slider.onCommit = { [weak self] in
      self?.app.isDraggingBrightness = false
      self?.app.commitBrightnessMemory()
    }
    brightnessSlider = slider
    let row = sliderRow("sun.max", slider)
    brightnessRow = row
    return row
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
      let row = sliderRow("paintpalette", slider)
      colorRow = row
      return row
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
      let row = sliderRow("thermometer.medium", slider)
      colorRow = row
      return row
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

  /// The current scene + a chevron; tapping toggles the inline scene grid.
  private func makeSceneHeaderRow() -> NSView {
    let tap = TapControl { [weak self] in
      guard let self else { return }
      self.sceneListExpanded.toggle()
      self.scheduleSync()
    }
    tap.toolTip = sceneListExpanded ? "Hide scenes" : "Choose a scene"
    tap.layer?.cornerRadius = 6
    tap.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.06).cgColor

    let current = app.availableScenes.first { $0.id == app.state.scene?.id }
    let label = NSTextField(labelWithString: current?.name ?? "Choose a scene")
    label.font = .systemFont(ofSize: 12, weight: .medium)
    label.lineBreakMode = .byTruncatingTail
    label.translatesAutoresizingMaskIntoConstraints = false
    sceneHeaderLabel = label

    let chevron = NSImageView()
    chevron.image = NSImage(
      systemSymbolName: sceneListExpanded ? "chevron.up" : "chevron.down",
      accessibilityDescription: nil)
    chevron.contentTintColor = .secondaryLabelColor
    chevron.translatesAutoresizingMaskIntoConstraints = false

    tap.addSubview(label)
    tap.addSubview(chevron)
    tap.heightAnchor.constraint(equalToConstant: 30).isActive = true
    NSLayoutConstraint.activate([
      label.leadingAnchor.constraint(equalTo: tap.leadingAnchor, constant: 10),
      label.centerYAnchor.constraint(equalTo: tap.centerYAnchor),
      chevron.trailingAnchor.constraint(equalTo: tap.trailingAnchor, constant: -10),
      chevron.centerYAnchor.constraint(equalTo: tap.centerYAnchor),
      label.trailingAnchor.constraint(lessThanOrEqualTo: chevron.leadingAnchor, constant: -8),
    ])
    return fullWidth(tap)
  }

  /// A two-column grid of the bulb's scenes; tapping one runs it and collapses.
  private func makeSceneGrid() -> NSView {
    let col = NSStackView()
    col.orientation = .vertical
    col.alignment = .leading
    col.spacing = 6
    let scenes = app.availableScenes
    var i = 0
    while i < scenes.count {
      let pair = NSStackView()
      pair.orientation = .horizontal
      pair.spacing = 6
      pair.distribution = .fillEqually
      for scene in scenes[i..<min(i + 2, scenes.count)] { pair.addArrangedSubview(sceneChip(scene)) }
      if scenes.count - i == 1 { pair.addArrangedSubview(NSView()) }  // keep a lone chip half-width
      pair.translatesAutoresizingMaskIntoConstraints = false
      col.addArrangedSubview(pair)
      pair.widthAnchor.constraint(equalTo: col.widthAnchor).isActive = true
      i += 2
    }
    return fullWidth(col)
  }

  private func sceneChip(_ scene: LightScene) -> NSView {
    let tap = TapControl { [weak self] in
      self?.app.applyScene(scene.id)  // keep the grid open (and the menu) so you can pick another
    }
    tap.toolTip = scene.hint.isEmpty ? scene.name : "\(scene.name) — \(scene.hint)"
    tap.layer?.cornerRadius = 6
    // Soft per-scene tint behind the glyph (the "coloured tiles" look).
    tap.layer?.backgroundColor = Self.nsColor(scene.tint).withAlphaComponent(0.22).cgColor
    if app.state.scene?.id == scene.id {
      tap.layer?.borderColor = NSColor.controlAccentColor.cgColor
      tap.layer?.borderWidth = 2
    }

    let icon = NSImageView()
    icon.image = NSImage(systemSymbolName: scene.symbol, accessibilityDescription: scene.name)
    icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 16, weight: .regular)
    icon.contentTintColor = .labelColor
    icon.imageScaling = .scaleProportionallyDown  // tall-bbox symbols scale into the fixed 18pt height
    icon.translatesAutoresizingMaskIntoConstraints = false

    let label = NSTextField(labelWithString: scene.name)
    label.font = .systemFont(ofSize: 11)
    label.alignment = .center
    label.lineBreakMode = .byTruncatingTail
    label.translatesAutoresizingMaskIntoConstraints = false

    tap.addSubview(icon)
    tap.addSubview(label)
    // Equal top/bottom insets by construction: the icon's top sits 8 below the chip
    // top, and the text *baseline* 8 above the chip bottom. Pinning the baseline (not
    // the label frame) ignores the line box's descender padding, so the gap above the
    // icon and the gap below the visible text are both 8 — independent of how tall a
    // given SF Symbol's bounding box is. The fixed 18pt icon height keeps chips uniform.
    tap.heightAnchor.constraint(equalToConstant: 50).isActive = true
    NSLayoutConstraint.activate([
      icon.heightAnchor.constraint(equalToConstant: 18),
      icon.topAnchor.constraint(equalTo: tap.topAnchor, constant: 8),
      icon.centerXAnchor.constraint(equalTo: tap.centerXAnchor),
      label.lastBaselineAnchor.constraint(equalTo: tap.bottomAnchor, constant: -8),
      label.leadingAnchor.constraint(equalTo: tap.leadingAnchor, constant: 6),
      label.trailingAnchor.constraint(equalTo: tap.trailingAnchor, constant: -6),
    ])
    return tap
  }

  private func makeSpeedRow() -> NSView {
    let slider = GradientSliderControl()
    // The engine's firmware band (10–200, 100 = normal), so the slider can't
    // drift from what clampSpeed enforces.
    slider.minValue = Double(app.core.speedRange.lowerBound)
    slider.maxValue = Double(app.core.speedRange.upperBound)
    slider.value = Double(app.state.scene?.speed ?? 100)
    // A progress track: accent-filled up to the thumb, grey after it.
    slider.progressFill = (filled: .controlAccentColor, unfilled: Self.nsColor([90, 90, 90]))
    slider.onEditing = { [weak self] v in self?.app.setSceneSpeed(Int(v.rounded())) }
    speedSlider = slider
    let row = sliderRow("speedometer", slider)
    speedRow = row
    return row
  }

  private func makeDisconnected() -> NSView {
    let col = NSStackView()
    col.orientation = .vertical
    col.alignment = .leading
    col.spacing = 8

    guard app.hasLight else {
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
      return fullWidth(col)
    }

    // A saved light is selected — show the live connection phase.
    if app.isConnecting {
      let spinner = NSProgressIndicator()
      spinner.style = .spinning
      spinner.controlSize = .small
      spinner.startAnimation(nil)
      spinner.translatesAutoresizingMaskIntoConstraints = false
      spinner.widthAnchor.constraint(equalToConstant: 16).isActive = true
      spinner.heightAnchor.constraint(equalToConstant: 16).isActive = true
      let label = NSTextField(labelWithString: "Connecting to \(app.displayName)…")
      label.font = .systemFont(ofSize: NSFont.systemFontSize)
      label.textColor = .secondaryLabelColor
      label.lineBreakMode = .byTruncatingTail
      let row = NSStackView(views: [spinner, label])
      row.orientation = .horizontal
      row.spacing = 8
      row.alignment = .centerY
      col.addArrangedSubview(fullWidth(row))
      return fullWidth(col)
    }

    // On a failed attempt, lead with the reason (in red) above the Connect button.
    if case .error(let message) = app.status {
      let caption = NSTextField(wrappingLabelWithString: message)
      caption.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
      caption.textColor = .systemRed
      caption.preferredMaxLayoutWidth = Self.contentWidth
      col.addArrangedSubview(fullWidth(caption))
    }

    let button = NSButton(
      title: "Connect to \(app.displayName)", target: self, action: #selector(connect))
    button.bezelStyle = .rounded
    button.controlSize = .large
    col.addArrangedSubview(fullWidth(button))
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
    let modes = popoverModes
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
    switch app.status {
    case .connected: return "Device: \(app.displayName)"
    case .connecting: return app.hasLight ? "Connecting to \(app.displayName)…" : "Connecting…"
    case .error, .disconnected: return app.hasLight ? "Not connected" : "No light selected"
    case .noLight: return "No light selected"
    }
  }

  /// Hover hint for the device name — the full (untruncated) name, then IP +
  /// capabilities, else a state-appropriate nudge (not connected / nothing set up).
  private var deviceTooltip: String {
    if app.connected {
      let details = [app.selectedIp, app.deviceSummary].filter { !$0.isEmpty }
        .joined(separator: " · ")
      return details.isEmpty ? app.displayName : "\(app.displayName)\n\(details)"
    }
    if app.hasLight { return "\(app.displayName) — not connected" }
    return "No light selected — Discover one to get started"
  }

  /// Hover hint for each mode-picker segment.
  private func modeTooltip(_ mode: AppState.ColorMode) -> String {
    switch mode {
    case .rgb: return "Colour"
    case .white: return "White — colour temperature"
    case .warmGlow: return "Warm Glow — temperature follows brightness"
    case .scene: return "Dynamic scenes"
    }
  }

  private var liveNSColor: NSColor {
    // Scenes mode: ramp the brightness track to white, not the (stale) preserved colour.
    if app.colorMode == .scene { return Self.nsColor([255, 255, 255]) }
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
