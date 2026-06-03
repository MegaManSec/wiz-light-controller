import AppKit
import SwiftUI
import WizKit

/// The menu-bar dropdown, as a SwiftUI popover instead of an `NSMenu` — so it
/// updates live and animates: switching mode fades the colour/temperature row in
/// and out (and collapses it for Warm Glow) without closing. Compact by design
/// (sliders + a mode switcher), with the light name and open-controls / quit
/// buttons in the header, mirroring the Control Center panel.
struct DropdownView: View {
  @EnvironmentObject var app: AppState
  var onOpenControls: () -> Void = {}
  var onQuit: () -> Void = {}

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      if UpdateChecker.shared.updateAvailable, let latest = UpdateChecker.shared.latestVersion {
        updateRow(latest)
      }
      header
      if app.connected {
        Divider()
        controls
      }
    }
    .padding(14)
    .frame(width: 290)
    .animation(.easeInOut(duration: 0.22), value: app.colorMode)
    .animation(.easeInOut(duration: 0.22), value: app.connected)
  }

  // MARK: - Header

  /// The app's icon artwork loaded from the bundled .icns so it keeps its
  /// transparency — `NSApp.applicationIconImage` composites it onto a white tile.
  private static let appIcon: NSImage = {
    if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
      let img = NSImage(contentsOf: url)
    {
      return img
    }
    return NSApplication.shared.applicationIconImage
  }()

  private var header: some View {
    HStack(spacing: 8) {
      Image(nsImage: Self.appIcon)
        .resizable()
        .aspectRatio(contentMode: .fit)
        .frame(width: 18, height: 18)
      Text(headerText)
        .font(.subheadline.weight(.semibold)).lineLimit(1).truncationMode(.tail)
        .help(headerText)  // full, untruncated device name on hover
        .offset(y: 2)  // nudge the text down to sit centered with the icon + buttons
      Spacer(minLength: 8)
      circleButton("slider.horizontal.3", "Open the controls window", onOpenControls)
      circleButton("xmark", "Quit WiZ Light Controller", onQuit)
    }
  }

  /// Header label: the connected device, or a short status when not connected.
  private var headerText: String {
    if app.connected { return "Device: \(app.displayName)" }
    if app.hasLight { return "Not connected" }
    return "No light selected"
  }

  private func circleButton(_ symbol: String, _ help: String, _ action: @escaping () -> Void)
    -> some View
  {
    Button(action: action) {
      Image(systemName: symbol)
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(.primary)
        .frame(width: 22, height: 22)
        .background(Circle().fill(.secondary.opacity(0.18)))
    }
    .buttonStyle(.plain)
    .help(help)
  }

  private func updateRow(_ latest: String) -> some View {
    Button {
      if let url = UpdateChecker.shared.releasePageURL { NSWorkspace.shared.open(url) }
    } label: {
      Label("Update available: v\(latest)", systemImage: "arrow.down.circle.fill")
        .font(.caption)
    }
    .buttonStyle(.plain)
    .foregroundStyle(.secondary)
  }

  // MARK: - Controls

  @ViewBuilder private var controls: some View {
    HStack(spacing: 12) {
      Toggle("", isOn: Binding(get: { app.state.on }, set: { app.setPower($0) }))
        .labelsHidden().toggleStyle(.switch)
      Picker("", selection: Binding(get: { app.colorMode }, set: { app.setColorMode($0) })) {
        ForEach(AppState.ColorMode.allCases) { Text($0.label).tag($0) }
      }
      .labelsHidden().pickerStyle(.segmented)
    }

    // Brightness stays visible even when off (knob at 0) — slide up to turn on.
    sliderRow(
      "sun.max",
      Binding(
        get: { app.state.on ? Double(app.state.brightness) : 0 },
        set: { app.setBrightnessLevel(Int($0.rounded())) }),
      0...100, [Color(rgb: [43, 43, 43]), app.liveColor],
      onCommit: { app.commitBrightnessMemory() })

    // Colour / temperature — fades as it swaps hue↔temp and collapses for Warm Glow.
    if !app.warmGlow {
      colorRow.id(app.state.mode).transition(.opacity)
    }
  }

  @ViewBuilder private var colorRow: some View {
    if app.state.mode == .rgb {
      sliderRow(
        "paintpalette",
        Binding(
          get: { app.hsv.h },
          // A fully-desaturated colour has no hue to move, so give it a usable
          // saturation when the hue is dragged (mirrors the old menu slider).
          set: { app.setHSV(h: $0, s: app.hsv.s < 1 ? 100 : app.hsv.s, v: max(1, app.hsv.v)) }),
        0...359, hueStops())  // 360° == 0° (both red); cap so it doesn't wrap to the left
    } else {
      sliderRow(
        "thermometer.medium",
        Binding(
          get: { Double(app.state.temp) },
          set: {
            app.state.temp = app.clampTemp(Int(($0 / 100).rounded()) * 100)
            app.state.mode = .white
            app.applyLive()
          }),
        Double(app.tempRange.lowerBound)...Double(app.tempRange.upperBound), tempStops())
    }
  }

  private func sliderRow(
    _ symbol: String, _ value: Binding<Double>, _ range: ClosedRange<Double>, _ colors: [Color],
    onCommit: @escaping () -> Void = {}
  ) -> some View {
    HStack(spacing: 10) {
      Image(systemName: symbol)
        .font(.system(size: 13)).foregroundStyle(.secondary)
        .frame(width: 18)
      GradientSlider(value: value, range: range, colors: colors, onCommit: onCommit)
    }
  }

  private func hueStops() -> [Color] {
    stride(from: 0.0, through: 360.0, by: 60.0).map {
      Color(rgb: app.core.hsvToRgb([$0 / 360, 1, 1]))
    }
  }

  private func tempStops() -> [Color] {
    let lo = app.tempRange.lowerBound
    let hi = app.tempRange.upperBound
    return stride(from: 0.0, through: 1.0, by: 0.25).map {
      Color(rgb: app.core.kelvinToRgb(Int(Double(lo) + $0 * Double(hi - lo))))
    }
  }
}
