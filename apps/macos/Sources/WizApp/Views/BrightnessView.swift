import SwiftUI
import WizKit

/// Brightness slider (0–100%) whose track is tinted from a dark base up to the
/// live colour — the live RGB in colour mode, or `kelvinToRgb(temp)` in white
/// mode — mirroring the Python app's brightness gradient.
struct BrightnessView: View {
  @EnvironmentObject var app: AppState

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack {
        Label("Brightness", systemImage: "sun.max")
          .font(.subheadline)
        Spacer()
        Text(app.state.on ? "\(app.state.brightness)%" : "Off")
          .font(.caption.monospacedDigit())
          .foregroundStyle(.secondary)
      }
      GradientSlider(
        value: brightnessBinding,
        range: 0...100,
        colors: [Color(rgb: [43, 43, 43]), tintColor],
        onEditing: { app.isDraggingBrightness = true },
        onCommit: {
          app.isDraggingBrightness = false
          app.commitBrightnessMemory()
        })
    }
  }

  /// Slider value as Double, writing back a clamped Int via the engine.
  private var brightnessBinding: Binding<Double> {
    Binding(
      get: { app.state.on ? Double(app.state.brightness) : 0 },
      set: { app.setBrightnessLevel(Int($0.rounded())) })  // 0 turns the light off
  }

  /// The colour the track ramps toward.
  private var tintColor: Color {
    // In Scenes mode the colour is an animation, not one hue, so ramp to white — a
    // neutral dark→light brightness fade rather than a stale (preserved) colour tint.
    if app.colorMode == .scene { return Color(rgb: [255, 255, 255]) }
    let rgb = app.state.mode == .rgb ? app.state.rgb : app.core.kelvinToRgb(app.state.temp)
    return Color(rgb: rgb)
  }
}

/// White-mode colour temperature slider over the bulb's negotiated white range
/// (`app.tempRange`, from the bulb's `cctRange`) with a warm→cool gradient.
struct WhiteTempView: View {
  @EnvironmentObject var app: AppState

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack {
        Label("Temperature", systemImage: "thermometer.medium")
          .font(.subheadline)
        Spacer()
        Text("\(app.state.temp)K")
          .font(.caption.monospacedDigit())
          .foregroundStyle(.secondary)
      }
      GradientSlider(
        value: tempBinding,
        range: Double(app.tempRange.lowerBound)...Double(app.tempRange.upperBound),
        colors: [Color(rgb: app.core.kelvinToRgb(app.tempRange.lowerBound)),
                 Color(rgb: [255, 255, 255])],
        onEditing: { app.applyLive() })
    }
  }

  /// Snap to the nearest 100K (matches the Python app), clamped via the engine.
  private var tempBinding: Binding<Double> {
    Binding(
      get: { Double(app.state.temp) },
      set: {
        let snapped = Int(($0 / 100).rounded()) * 100
        app.state.temp = app.clampTemp(snapped)
      })
  }
}

/// Warm Glow's colour temperature — a *locked* slider showing where the auto
/// temperature (which follows brightness via the bulb's dim-to-warm curve)
/// currently sits. Read-only: in this mode you set brightness, and the temperature
/// tracks it (down to its warmest end as brightness hits 0).
struct WarmGlowTempView: View {
  @EnvironmentObject var app: AppState

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack {
        Label("Temperature", systemImage: "thermometer.medium")
          .font(.subheadline)
        Spacer()
        Text("\(app.warmGlowDisplayKelvin)K")
          .font(.caption.monospacedDigit())
          .foregroundStyle(.secondary)
      }
      GradientSlider(
        value: .constant(thumbTemp),
        range: warmGlowRange,
        colors: [Color(rgb: app.core.kelvinToRgb(app.tempRange.lowerBound)),
                 Color(rgb: [255, 255, 255])])
        .disabled(true)
        .opacity(0.8)
      Label("Follows brightness automatically", systemImage: "lock.fill")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
  }

  /// The full device white range (same bar as the White tab); the thumb sits where
  /// the auto temperature currently falls — Warm Glow only sweeps the warm part of it.
  private var warmGlowRange: ClosedRange<Double> {
    Double(app.tempRange.lowerBound)...Double(app.tempRange.upperBound)
  }

  /// Displayed temperature, clamped into the bar's range for the (locked) thumb.
  private var thumbTemp: Double {
    min(max(Double(app.warmGlowDisplayKelvin), warmGlowRange.lowerBound), warmGlowRange.upperBound)
  }
}
