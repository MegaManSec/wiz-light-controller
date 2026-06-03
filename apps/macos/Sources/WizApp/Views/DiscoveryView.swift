import SwiftUI
import WizKit

/// Discovery sheet: scan the LAN, list discovered + saved lights, and let the
/// user select / save / rename / remove. Auto-updating a saved light's IP when
/// its MAC reappears is handled in `AppState.discover()`.
struct DiscoveryView: View {
  @EnvironmentObject var app: AppState
  @Environment(\.dismiss) private var dismiss

  /// MAC currently being renamed, plus the editable text.
  @State private var renamingMac: String?
  @State private var renameText = ""

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      header
      Divider()
      List {
        if !app.savedLights.isEmpty {
          Section("Saved") {
            ForEach(app.savedLights.sorted { $0.value.name < $1.value.name }, id: \.key) { mac, light in
              savedRow(mac: mac, light: light)
            }
          }
        }
        Section(app.isDiscovering ? "Discovering…" : "Found") {
          if app.discovered.isEmpty {
            Text(app.isDiscovering ? "Scanning the network…" : "No lights found yet. Tap Scan.")
              .foregroundStyle(.secondary)
          }
          ForEach(app.discovered, id: \.mac) { light in
            discoveredRow(light)
          }
        }
      }
      .listStyle(.inset)
    }
    .padding(16)
    .frame(width: 460, height: 460)
    .onAppear { if app.discovered.isEmpty { app.discover() } }
  }

  private var header: some View {
    HStack {
      Text("Discover Lights").font(.title2.bold())
      Spacer()
      Button {
        app.discover()
      } label: {
        if app.isDiscovering {
          ProgressView().controlSize(.small)
        } else {
          Label("Scan", systemImage: "arrow.clockwise")
        }
      }
      .disabled(app.isDiscovering)
      Button("Done") { dismiss() }
        .keyboardShortcut(.defaultAction)
    }
  }

  // MARK: - Rows

  @ViewBuilder
  private func savedRow(mac: String, light: Stores.SavedLight) -> some View {
    HStack {
      Image(systemName: mac == app.selectedMac ? "checkmark.circle.fill" : "lightbulb")
        .foregroundStyle(mac == app.selectedMac ? Color.green : Color.secondary)
      if renamingMac == mac {
        TextField("Name", text: $renameText, onCommit: {
          app.renameSavedLight(mac: mac, name: renameText)
          renamingMac = nil
        })
        .textFieldStyle(.roundedBorder)
      } else {
        VStack(alignment: .leading) {
          Text(light.name)
          Text(light.ip).font(.caption).foregroundStyle(.secondary)
        }
      }
      Spacer()
      Button("Select") {
        app.selectLight(name: light.name, ip: light.ip, mac: mac)
        if app.settings.autoSync { app.sync() }
        dismiss()
      }
      Menu {
        Button("Rename") { renamingMac = mac; renameText = light.name }
        Button("Remove", role: .destructive) { app.removeSavedLight(mac: mac) }
      } label: {
        Image(systemName: "ellipsis.circle")
      }
      .menuStyle(.borderlessButton)
      .frame(width: 28)
    }
  }

  @ViewBuilder
  private func discoveredRow(_ light: Discovery.Light) -> some View {
    let isSaved = !light.mac.isEmpty && app.savedLights[light.mac] != nil
    HStack {
      Image(systemName: "lightbulb")
        .foregroundStyle(.secondary)
      VStack(alignment: .leading) {
        Text(light.name)
        Text(light.ip + (light.mac.isEmpty ? "" : " · \(app.core.formatMac(light.mac))"))
          .font(.caption).foregroundStyle(.secondary)
      }
      Spacer()
      Button("Select") {
        app.selectLight(name: light.name, ip: light.ip, mac: light.mac)
        if app.settings.autoSync { app.sync() }
        dismiss()
      }
      if !isSaved, !light.mac.isEmpty {
        Button("Save") {
          app.selectLight(name: light.name, ip: light.ip, mac: light.mac)
          app.saveCurrentLight(name: light.name)
        }
      }
    }
  }
}
