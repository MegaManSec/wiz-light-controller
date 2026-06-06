import SwiftUI
import WizKit

/// The dynamic-scene picker, shown when the controls-window mode is "Scenes".
/// A grid of the scenes this bulb supports (detected on connect) — clicking runs
/// one and the active scene is ringed — plus a speed slider for the running scene.
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
      // Speed only matters while a scene is running (and only animated ones honour
      // it, but the bulb ignores it harmlessly otherwise).
      if app.state.scene != nil {
        speedRow
      }
    }
  }

  private var speedRow: some View {
    HStack(spacing: 10) {
      Text("Speed")
        .font(.caption.monospaced())
        .frame(width: 44, alignment: .leading)
      Slider(
        value: Binding(
          get: { Double(app.state.scene?.speed ?? 100) },
          set: { app.setSceneSpeed(Int($0.rounded())) }),
        in: 1...100)
      Text("\(app.state.scene?.speed ?? 100)")
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
        .frame(width: 36, alignment: .trailing)
    }
    .padding(.top, 2)
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
      Text(scene.name)
        .font(.caption)
        .lineLimit(1)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06)))
        .overlay(
          RoundedRectangle(cornerRadius: 8)
            .strokeBorder(active ? Color.accentColor : .clear, lineWidth: 2))
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }

  private var active: Bool { app.isSceneActive(scene.id) }
}
