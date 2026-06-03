import Foundation
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
        range: 0...359,  // 360° == 0° (both red); cap at 359 so it doesn't wrap to the left
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
          // Floor at 1: value 0 is pure black, which the bulb can't show, so
          // `setRGB` rejects it — without the floor the thumb would stick at 0.
          set: { app.setHSV(h: app.hsv.h, s: app.hsv.s, v: max(1, $0)) }),
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

/// Hex entry kept in sync with the live colour. The six expected digits show as a
/// greyed template behind whatever's been typed, input is sanitised to hex (max
/// six), it commits on submit, and an incomplete entry shakes with a red border
/// instead of being silently ignored.
private struct HexField: View {
  @EnvironmentObject var app: AppState
  @State private var text = ""
  @State private var invalid = false
  @State private var shake: CGFloat = 0

  private static let template = "FFFFFF"

  var body: some View {
    HStack(spacing: 10) {
      Text("Hex")
        .font(.caption.monospaced())
        .frame(width: 32, alignment: .leading)
      entry
      RoundedRectangle(cornerRadius: 4)
        .fill(app.liveColor)
        .frame(width: 24, height: 18)
        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.black.opacity(0.2)))
      Spacer()
    }
    .onAppear { text = sanitize(app.hex) }
    .onChange(of: app.hex) { text = sanitize($0) }
  }

  /// `#` + a fixed-width field where the typed digits sit over a greyed six-digit
  /// template; the not-yet-typed positions stay greyed.
  private var entry: some View {
    HStack(spacing: 1) {
      Text("#").foregroundStyle(.secondary)
      ZStack(alignment: .leading) {
        Text(ghost).foregroundStyle(.tertiary)
        TextField("", text: $text)
          .textFieldStyle(.plain)
          .onChange(of: text) { text = sanitize($0) }
          .onSubmit(submit)
      }
      .frame(width: 62, alignment: .leading)
    }
    .font(.system(.body, design: .monospaced))
    .padding(.horizontal, 7)
    .padding(.vertical, 4)
    .background(RoundedRectangle(cornerRadius: 5).fill(Color(nsColor: .textBackgroundColor)))
    .overlay(
      RoundedRectangle(cornerRadius: 5)
        .strokeBorder(invalid ? .red : Color(nsColor: .separatorColor), lineWidth: invalid ? 1.5 : 1)
    )
    .modifier(Shake(animatableData: shake))
  }

  /// Spaces over the already-typed positions, then the remaining template digits,
  /// so grey only shows for characters still to be entered.
  private var ghost: String {
    let typed = min(text.count, Self.template.count)
    return String(repeating: " ", count: typed) + String(Self.template.dropFirst(typed))
  }

  /// Hex digits only, upper-cased, capped at six.
  private func sanitize(_ s: String) -> String {
    String(s.uppercased().filter { $0.isHexDigit }.prefix(6))
  }

  private func submit() {
    // Reject incomplete input and pure black (which the bulb can't show).
    if text.count == 6, text != "000000" {
      invalid = false
      app.setHex(text)
    } else {
      flagInvalid()
    }
  }

  /// Red border + a brief horizontal shake to flag an incomplete hex.
  private func flagInvalid() {
    invalid = true
    withAnimation(.linear(duration: 0.4)) { shake += 2 }
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { invalid = false }
  }
}

/// A brief left-right shake. Driven by animating `animatableData` by a whole
/// number (the field bumps it by 2 to play one burst), so it begins and ends
/// centred without snapping back.
private struct Shake: GeometryEffect {
  var travel: CGFloat = 5
  var cycles: CGFloat = 3
  var animatableData: CGFloat

  func effectValue(size: CGSize) -> ProjectionTransform {
    ProjectionTransform(
      CGAffineTransform(translationX: travel * sin(animatableData * .pi * cycles), y: 0))
  }
}
