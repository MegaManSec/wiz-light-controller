import AppKit
import SwiftUI
import WizKit

/// Two preset grids (RGB + White) from the store. Clicking applies; the active
/// preset (per `stateMatchesPreset`) is ringed in the highlight colour. A
/// "Save current…" button persists the live state as a preset in the current mode.
struct PresetsView: View {
  @EnvironmentObject var app: AppState
  @State private var showSave = false
  @State private var saveName = ""

  private let columns = [GridItem(.adaptive(minimum: 96), spacing: 8)]

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Text("Presets").font(.headline)
        Spacer()
        // Warm Glow presets are a fixed set, so only RGB/White offer "Save current".
        if app.colorMode != .warmGlow {
          Button {
            saveName = ""
            showSave = true
          } label: {
            Label("Save current…", systemImage: "plus")
          }
          .disabled(!app.hasLight)
        }
      }

      // Show only the active mode's presets.
      switch app.colorMode {
      case .rgb: grid(for: .rgb, title: "RGB")
      case .white: grid(for: .white, title: "White")
      case .warmGlow: warmGlowGrid
      case .scene: EmptyView()  // scenes use ScenesView, not the preset grids
      }
    }
    .popover(isPresented: $showSave) { savePopover }
  }

  @ViewBuilder
  private func grid(for mode: LightMode, title: String) -> some View {
    let items = app.presets[mode] ?? []
    if !items.isEmpty {
      Text(title).font(.subheadline).foregroundStyle(.secondary)
      LazyVGrid(columns: columns, spacing: 8) {
        ForEach(items) { preset in
          PresetChip(preset: preset)
        }
      }
    }
  }

  @ViewBuilder
  private var warmGlowGrid: some View {
    Text("Warm Glow").font(.subheadline).foregroundStyle(.secondary)
    LazyVGrid(columns: columns, spacing: 8) {
      ForEach(app.warmGlowPresets) { preset in
        WarmGlowChip(preset: preset)
      }
    }
  }

  private var savePopover: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("Save current \(app.state.mode == .rgb ? "RGB" : "White") preset")
        .font(.headline)
      TextField("Preset name", text: $saveName)
        .textFieldStyle(.roundedBorder)
        .frame(width: 220)
      HStack {
        Spacer()
        Button("Cancel") { showSave = false }
        Button("Save") {
          app.saveCurrentAsPreset(name: saveName)
          showSave = false
        }
        .keyboardShortcut(.defaultAction)
        .disabled(saveName.trimmingCharacters(in: .whitespaces).isEmpty)
      }
    }
    .padding(16)
  }
}

/// A single tappable preset swatch. Shows its colour (or a warm/cool dot for
/// white presets), its name, and a highlight ring when it's the active preset.
private struct PresetChip: View {
  @EnvironmentObject var app: AppState
  let preset: Preset

  var body: some View {
    Button {
      app.applyPreset(preset)
    } label: {
      VStack(spacing: 6) {
        RoundedRectangle(cornerRadius: 6)
          .fill(swatchColor)
          .frame(height: 34)
          .overlay(
            RoundedRectangle(cornerRadius: 6)
              .strokeBorder(.black.opacity(0.15), lineWidth: 1))
        Text(preset.name)
          .font(.caption)
          .lineLimit(1)
      }
      .padding(6)
      .background(
        RoundedRectangle(cornerRadius: 8)
          .fill(Color.primary.opacity(0.06)))
      .overlay(
        RoundedRectangle(cornerRadius: 8)
          .strokeBorder(active ? Color.accentColor : .clear, lineWidth: 2))
      .contentShape(Rectangle())
      .background(ToolTip(text: helpText))
    }
    .buttonStyle(.plain)
    .contextMenu {
      Button("Delete", role: .destructive) { app.deletePreset(preset) }
    }
  }

  private var active: Bool { app.isActive(preset) }

  /// Tooltip describing the preset — its colour or temperature, plus brightness.
  private var helpText: String {
    if preset.mode == .rgb {
      let hex = app.core.rgbToHex([preset.r ?? 0, preset.g ?? 0, preset.b ?? 0]).uppercased()
      return "\(preset.name) — \(hex), \(preset.brightness)%"
    }
    return "\(preset.name) — \(app.clampTemp(preset.temp ?? 4000)) K, \(preset.brightness)%"
  }

  /// RGB presets show their colour; white presets show their kelvin colour.
  private var swatchColor: Color {
    if preset.mode == .rgb {
      return Color(rgb: [preset.r ?? 0, preset.g ?? 0, preset.b ?? 0])
    }
    return Color(rgb: app.core.kelvinToRgb(app.clampTemp(preset.temp ?? 4000)))
  }
}

/// A Warm Glow preset swatch — a warm dot at the level's auto temperature, named
/// for the level. Applying switches to Warm Glow at that brightness.
private struct WarmGlowChip: View {
  @EnvironmentObject var app: AppState
  let preset: AppState.WarmGlowPreset

  var body: some View {
    Button {
      app.applyWarmGlowPreset(preset)
    } label: {
      VStack(spacing: 6) {
        RoundedRectangle(cornerRadius: 6)
          .fill(Color(rgb: app.core.kelvinToRgb(app.kelvinForBrightness(preset.brightness))))
          .frame(height: 34)
          .overlay(
            RoundedRectangle(cornerRadius: 6)
              .strokeBorder(.black.opacity(0.15), lineWidth: 1))
        Text(preset.name)
          .font(.caption)
          .lineLimit(1)
      }
      .padding(6)
      .background(
        RoundedRectangle(cornerRadius: 8)
          .fill(Color.primary.opacity(0.06)))
      .overlay(
        RoundedRectangle(cornerRadius: 8)
          .strokeBorder(active ? Color.accentColor : .clear, lineWidth: 2))
      .contentShape(Rectangle())
      .background(
        ToolTip(text: "\(preset.name) — \(preset.brightness)%, ≈\(app.kelvinForBrightness(preset.brightness)) K"))
    }
    .buttonStyle(.plain)
  }

  private var active: Bool { app.warmGlow && app.state.brightness == preset.brightness }
}

/// A transparent NSView that carries a native tooltip over its whole frame.
/// SwiftUI's `.help` only tracks drawn pixels (so it misses the chip margins);
/// an AppKit tooltip rect covers the entire backing view reliably.
private struct ToolTip: NSViewRepresentable {
  let text: String
  func makeNSView(context: Context) -> NSView {
    let view = NSView()
    view.toolTip = text
    return view
  }
  func updateNSView(_ view: NSView, context: Context) {
    view.toolTip = text
  }
}
