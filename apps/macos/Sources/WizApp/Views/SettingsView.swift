import SwiftUI
import WizKit

/// App settings: the auto-sync toggle and the update-check controls, persisted.
struct SettingsView: View {
  @EnvironmentObject var app: AppState

  var body: some View {
    Form {
      // Device facts are live readings — only meaningful while connected. With
      // nothing connected there's nothing to show but a column of em dashes, so
      // hide the whole section.
      if app.connected {
        Section("Device") {
          InfoRow("Signal", signalText)
          InfoRow("MAC", app.deviceInfo.mac.isEmpty ? "—" : app.core.formatMac(app.deviceInfo.mac))
          InfoRow("Firmware", app.deviceInfo.firmware.isEmpty ? "—" : app.deviceInfo.firmware)
          ModelRow(model: app.deviceInfo.moduleName, summary: app.deviceSummary)
        }
      }
      Section("Behaviour") {
        Toggle("Auto-sync from the light on launch", isOn: autoSyncBinding)
        Toggle("Turn the light off when the Mac sleeps", isOn: $app.powerOffOnSleep)
        Toggle("Turn the light off when the Mac shuts down", isOn: $app.powerOffOnShutdown)
      }
      Section("Updates") {
        UpdateRow()
      }
    }
    .formStyle(.grouped)
    .padding(.top, 4)
  }

  private var autoSyncBinding: Binding<Bool> {
    Binding(
      get: { app.settings.autoSync },
      set: {
        app.settings.autoSync = $0
        app.persist()
      })
  }

  /// Signal strength with a qualitative label, or "—" when unknown/disconnected.
  private var signalText: String {
    guard app.connected, let rssi = app.deviceInfo.rssi else { return "—" }
    let quality: String
    switch rssi {
    case (-55)...: quality = "Excellent"
    case (-65)..<(-55): quality = "Good"
    case (-75)..<(-65): quality = "Fair"
    default: quality = "Weak"
    }
    return "\(rssi) dBm · \(quality)"
  }
}

/// The "Model" row: the bulb's module name, with its engine-derived capability
/// summary (e.g. "RGB + tunable white 2700–6500 K") beneath it when known.
private struct ModelRow: View {
  let model: String
  let summary: String

  var body: some View {
    HStack(alignment: .firstTextBaseline) {
      Text("Model")
      Spacer()
      VStack(alignment: .trailing, spacing: 2) {
        Text(model.isEmpty ? "—" : model)
          .foregroundStyle(.secondary)
          .textSelection(.enabled)
        if !summary.isEmpty {
          Text(summary)
            .font(.caption)
            .foregroundStyle(.tertiary)
        }
      }
    }
  }
}

/// A read-only label + value row; the value is selectable so the MAC / firmware
/// can be copied.
private struct InfoRow: View {
  let label: String
  let value: String

  init(_ label: String, _ value: String) {
    self.label = label
    self.value = value
  }

  var body: some View {
    HStack {
      Text(label)
      Spacer()
      Text(value)
        .foregroundStyle(.secondary)
        .textSelection(.enabled)
    }
  }
}

/// "Check for Updates" with state, plus a link to the release page when one is
/// available.
private struct UpdateRow: View {
  @ObservedObject private var checker = UpdateChecker.shared

  var body: some View {
    Toggle("Automatically check for updates", isOn: $checker.autoCheckEnabled)
    HStack {
      if checker.updateAvailable, let latest = checker.latestVersion {
        Label("Update available: v\(latest)", systemImage: "arrow.down.circle.fill")
        Spacer()
        if let url = checker.releasePageURL {
          Link("Open release", destination: url)
        }
      } else {
        Text("Version \(checker.currentVersion)")
        Spacer()
        Button(checker.isChecking ? "Checking…" : "Check for Updates") {
          checker.checkNow()
        }
        .disabled(checker.isChecking)
      }
    }
    if checker.lastCheckFailed {
      Text("Couldn't reach GitHub. Try again later.")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
  }
}
