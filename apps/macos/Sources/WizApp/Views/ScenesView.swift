import SwiftUI
import WizKit

/// The dynamic-scene picker, shown when the controls-window mode is "Scenes".
/// A grid of the scenes this bulb supports (detected on connect) — clicking runs
/// one and the active scene is ringed. The running scene's speed lives in
/// `SceneSpeedView`, placed below brightness in the controls window.
struct ScenesView: View {
  @EnvironmentObject var app: AppState

  private let columns = [GridItem(.adaptive(minimum: 96), spacing: 8)]

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("Scenes").font(.headline)
      LazyVGrid(columns: columns, spacing: 8) {
        ForEach(app.availableScenes) { scene in
          SceneChip(scene: scene)
        }
      }
    }
  }
}

/// The running scene's speed — a labelled, full-length slider matching the
/// brightness/temperature sliders (only animated scenes honour it, but the bulb
/// ignores it harmlessly otherwise).
struct SceneSpeedView: View {
  @EnvironmentObject var app: AppState

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack {
        Label("Speed", systemImage: "speedometer")
          .font(.subheadline)
        Spacer()
        // 100% = normal; the bulb only reports a speed once one has been set.
        Text("\(app.state.scene?.speed ?? 100)%")
          .font(.caption.monospacedDigit())
          .foregroundStyle(.secondary)
      }
      GradientSlider(
        value: Binding(
          get: { Double(app.state.scene?.speed ?? 100) },
          set: { app.setSceneSpeed(Int($0.rounded())) }),
        // The engine's firmware band (10–200), so the slider can't drift from
        // what clampSpeed enforces.
        range: Double(app.core.speedRange.lowerBound)...Double(app.core.speedRange.upperBound),
        colors: [],
        progressFill: (filled: .accentColor, unfilled: Color(rgb: [90, 90, 90])))
    }
  }
}

/// A single tappable scene tile, ringed in the accent colour when it's running.
private struct SceneChip: View {
  @EnvironmentObject var app: AppState
  let scene: LightScene

  var body: some View {
    Button {
      app.applyScene(scene.id)
    } label: {
      VStack(spacing: 6) {
        Image(systemName: scene.symbol)
          .font(.system(size: 20))
          .frame(height: 22)
        Text(scene.name)
          .font(.caption)
          .lineLimit(1)
      }
      .frame(maxWidth: .infinity)
      .padding(.vertical, 10)
      .background(RoundedRectangle(cornerRadius: 8).fill(tint.opacity(0.22)))
      .overlay(
        RoundedRectangle(cornerRadius: 8)
          .strokeBorder(active ? Color.accentColor : .clear, lineWidth: 2))
      .contentShape(Rectangle())
      .background(ToolTip(text: tooltip))
    }
    .buttonStyle(.plain)
  }

  /// Soft per-scene tile tint (the chosen "coloured tiles" look).
  private var tint: Color { Color(rgb: scene.tint) }

  /// Tooltip: the scene name plus its (approximate) colour/effect hint.
  private var tooltip: String { scene.hint.isEmpty ? scene.name : "\(scene.name) — \(scene.hint)" }

  private var active: Bool { app.isSceneActive(scene.id) }
}
