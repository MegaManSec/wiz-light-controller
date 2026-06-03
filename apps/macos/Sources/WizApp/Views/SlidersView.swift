import SwiftUI
import WizKit

/// RGB sliders + HSV sliders + a hex field, all kept in sync through `WizCore`
/// conversions — editing any one updates the others (the engine is the single
/// source of the maths). Each slider's track is tinted to preview the result,
/// mirroring the Python app.
struct SlidersView: View {
  @EnvironmentObject var app: AppState

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      rgbSection
      hsvSection
      hexField
    }
  }

  // MARK: - RGB

  private var rgbSection: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("RGB").font(.subheadline).foregroundStyle(.secondary)
      channel("R", index: 0, gradientFor: .r)
      channel("G", index: 1, gradientFor: .g)
      channel("B", index: 2, gradientFor: .b)
    }
  }

  private enum Chan { case r, g, b }

  /// One RGB channel slider. The track shows the colour as that channel sweeps
  /// 0→255 with the other two held at their current values.
  private func channel(_ label: String, index: Int, gradientFor chan: Chan) -> some View {
    let rgb = app.state.rgb
    let lo = trackColor(chan, value: 0, rgb: rgb)
    let hi = trackColor(chan, value: 255, rgb: rgb)
    return LabeledSlider(
      label: label,
      valueText: "\(rgb[index])",
      value: Binding(
        get: { Double(app.state.rgb[index]) },
        set: { newVal in
          var next = app.state.rgb
          next[index] = Int(newVal.rounded())
          app.setRGB(next)
        }),
      range: 0...255,
      colors: [lo, hi])
  }

  private func trackColor(_ chan: Chan, value: Int, rgb: [Int]) -> Color {
    var c = rgb
    switch chan {
    case .r: c[0] = value
    case .g: c[1] = value
    case .b: c[2] = value
    }
    return Color(rgb: c)
  }

  // MARK: - HSV

  private var hsvSection: some View {
    let hsv = app.hsv
    return VStack(alignment: .leading, spacing: 6) {
      Text("HSV").font(.subheadline).foregroundStyle(.secondary)

      // Hue: full rainbow.
      LabeledSlider(
        label: "H",
        valueText: "\(Int(hsv.h))°",
        value: Binding(
          get: { app.hsv.h },
          set: { app.setHSV(h: $0, s: app.hsv.s, v: app.hsv.v) }),
        range: 0...360,
        colors: hueStops())

      // Saturation: grey → full-sat colour at current hue/value.
      LabeledSlider(
        label: "S",
        valueText: "\(Int(hsv.s))%",
        value: Binding(
          get: { app.hsv.s },
          set: { app.setHSV(h: app.hsv.h, s: $0, v: app.hsv.v) }),
        range: 0...100,
        colors: [satColor(0), satColor(100)])

      // Value: black → full-brightness colour at current hue/sat.
      LabeledSlider(
        label: "V",
        valueText: "\(Int(hsv.v))%",
        value: Binding(
          get: { app.hsv.v },
          set: { app.setHSV(h: app.hsv.h, s: app.hsv.s, v: $0) }),
        range: 0...100,
        colors: [valColor(0), valColor(100)])
    }
  }

  /// Six rainbow stops for the hue track.
  private func hueStops() -> [Color] {
    stride(from: 0.0, through: 360.0, by: 60.0).map {
      Color(rgb: app.core.hsvToRgb([$0 / 360, 1, 1]))
    }
  }

  private func satColor(_ s: Double) -> Color {
    let hsv = app.hsv
    return Color(rgb: app.core.hsvToRgb([hsv.h / 360, s / 100, hsv.v / 100]))
  }

  private func valColor(_ v: Double) -> Color {
    let hsv = app.hsv
    return Color(rgb: app.core.hsvToRgb([hsv.h / 360, hsv.s / 100, v / 100]))
  }

  // MARK: - Hex

  private var hexField: some View {
    HexField()
  }
}

/// A labelled gradient slider with a trailing numeric readout. Shared by the RGB
/// and HSV rows.
private struct LabeledSlider: View {
  @EnvironmentObject var app: AppState
  let label: String
  let valueText: String
  @Binding var value: Double
  let range: ClosedRange<Double>
  let colors: [Color]

  var body: some View {
    HStack(spacing: 10) {
      Text(label)
        .font(.caption.monospaced())
        .frame(width: 16, alignment: .leading)
      GradientSlider(value: $value, range: range, colors: colors, onEditing: {})
      Text(valueText)
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
        .frame(width: 42, alignment: .trailing)
    }
  }
}

/// Hex entry kept in sync with the live colour. Commits on submit; rejects
/// invalid input (the engine's `hexToRgb` returns nil).
private struct HexField: View {
  @EnvironmentObject var app: AppState
  @State private var text = ""

  var body: some View {
    HStack(spacing: 10) {
      Text("Hex")
        .font(.caption.monospaced())
        .frame(width: 32, alignment: .leading)
      TextField("#ffffff", text: $text)
        .textFieldStyle(.roundedBorder)
        .frame(width: 110)
        .onSubmit { app.setHex(text) }
      RoundedRectangle(cornerRadius: 4)
        .fill(app.liveColor)
        .frame(width: 24, height: 18)
        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.black.opacity(0.2)))
      Spacer()
    }
    .onAppear { text = app.hex }
    .onChange(of: app.hex) { text = $0 }
  }
}
