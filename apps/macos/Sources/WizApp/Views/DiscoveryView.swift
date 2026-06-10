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

  /// Discovered lights that aren't already saved (saved ones appear under "Saved",
  /// matched by MAC).
  private var unsavedDiscovered: [Discovery.Light] {
    app.discovered.filter { app.savedLights[$0.mac] == nil }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      header
      Divider()
      List {
        if !app.savedLights.isEmpty {
          Section("Saved") {
            ForEach(app.savedLights.sorted { $0.value.name < $1.value.name }, id: \.key) { mac, light in
              savedRow(mac: mac, light: light)
                .listRowSeparator(.hidden)
            }
          }
        }
        Section(app.isDiscovering ? "Discovering…" : "Found") {
          if unsavedDiscovered.isEmpty {
            Text(app.isDiscovering ? "Scanning the network…" : "No new lights found. Tap Scan.")
              .foregroundStyle(.secondary)
              .listRowSeparator(.hidden)
          }
          // Identified by the whole value, not `\.mac` — replies without a MAC
          // all carry `""` there, which would collide as ForEach ids.
          ForEach(unsavedDiscovered, id: \.self) { light in
            discoveredRow(light)
              .listRowSeparator(.hidden)
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
    let connectedToThis = mac == app.selectedMac && app.connected
    let renaming = renamingMac == mac
    HStack {
      Image(systemName: connectedToThis ? "checkmark.circle.fill" : "lightbulb")
        .foregroundStyle(connectedToThis ? Color.green : Color.secondary)
      if renaming {
        TextField("Name", text: $renameText)
          .textFieldStyle(.roundedBorder)
          .onSubmit { commitRename(mac) }
          .onExitCommand { renamingMac = nil }  // Escape cancels without saving
      } else {
        VStack(alignment: .leading) {
          Text(light.name)
          Text("\(light.ip) · \(app.core.formatMac(mac))")
            .font(.caption).foregroundStyle(.secondary)
        }
      }
      Spacer()
      if renaming {
        Button("Save") { commitRename(mac) }
          .buttonStyle(.bordered)
        Button("Cancel") { renamingMac = nil }
          .buttonStyle(.bordered)
      } else {
        Button(connectedToThis ? "Disconnect" : "Connect") {
          if connectedToThis {
            app.disconnect()
          } else {
            app.selectLight(name: light.name, ip: light.ip, mac: mac)
          }
        }
        .buttonStyle(.bordered)
        Menu {
          Button("Rename") { renamingMac = mac; renameText = light.name }
          Button("Remove", role: .destructive) {
            app.removeSavedLight(mac: mac)
            app.discover()  // rescan so a removed light (if online) returns under "Found"
          }
        } label: {
          Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 28)
      }
    }
  }

  /// Commit a rename — the deliberate save (Save button or Enter). Escaping or
  /// clicking away leaves the name unchanged.
  private func commitRename(_ mac: String) {
    let trimmed = renameText.trimmingCharacters(in: .whitespaces)
    if !trimmed.isEmpty { app.renameSavedLight(mac: mac, name: trimmed) }
    renamingMac = nil
  }

  @ViewBuilder
  private func discoveredRow(_ light: Discovery.Light) -> some View {
    HStack {
      Image(systemName: "lightbulb")
        .foregroundStyle(.secondary)
      VStack(alignment: .leading) {
        Text(light.name)
        Text(light.ip + (light.mac.isEmpty ? "" : " · \(app.core.formatMac(light.mac))"))
          .font(.caption).foregroundStyle(.secondary)
      }
      Spacer()
      // Found lights can only be saved; selecting/connecting happens from Saved.
      if light.mac.isEmpty {
        Text("No MAC").font(.caption).foregroundStyle(.tertiary)
      } else {
        Button("Save") {
          app.saveLight(name: light.name, ip: light.ip, mac: light.mac)
        }
        .buttonStyle(.bordered)
      }
    }
  }
}
