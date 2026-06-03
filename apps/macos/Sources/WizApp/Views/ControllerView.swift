import SwiftUI
import WizKit

/// The main controller UI hosted in the manual window. A tab view: live controls
/// (connection, power, colour, brightness, presets) and settings. Reads/writes
/// `AppState`; every edit routes through `applyLive()` (the engine/WizClient
/// already debounces).
struct ControllerView: View {
  @EnvironmentObject var app: AppState

  var body: some View {
    TabView(selection: tabBinding) {
      controls
        .tabItem { Label("Controls", systemImage: "slider.horizontal.3") }
        .tag(ControllerWindowController.Tab.controls)
      SettingsView()
        .tabItem { Label("Settings", systemImage: "gearshape") }
        .tag(ControllerWindowController.Tab.settings)
    }
    .frame(minWidth: 600, minHeight: 500)
    .onAppear {
      if app.settings.autoSync, app.hasLight { app.sync() }
    }
  }

  private var tabBinding: Binding<ControllerWindowController.Tab> {
    Binding(get: { app.selectedTab }, set: { app.selectedTab = $0 })
  }

  // MARK: - Controls tab

  private var controls: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 18) {
        ConnectionBar()
        if app.connected {
          PowerModeBar()
          if app.state.on {
            if app.warmGlow {
              WarmGlowInfo()
            } else if app.state.mode == .rgb {
              ColorWheelView()
              SlidersView()
            } else {
              WhiteTempView()
            }
            BrightnessView()
            if !app.warmGlow { PresetsView() }
          }
        } else if app.hasLight {
          Label(
            "Not connected — press Connect to control \(app.displayName).",
            systemImage: "wifi.slash"
          )
          .foregroundStyle(.secondary)
          .padding(.top, 8)
        } else {
          Label(
            "No light selected. Enter a WiZ IP above or Discover a light.",
            systemImage: "wifi.slash"
          )
          .foregroundStyle(.secondary)
          .padding(.top, 8)
        }
      }
      .padding(20)
    }
  }
}

// MARK: - Connection bar (IP + discover + status)

/// IP entry, a Discover button (opens the discovery sheet), and a live
/// connection dot. Mirrors the Python app's top bar.
struct ConnectionBar: View {
  @EnvironmentObject var app: AppState
  @State private var ipText = ""
  @State private var showDiscovery = false

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 8) {
        Text("WiZ IP")
          .font(.headline)
        TextField("192.168.1.50", text: $ipText)
          .textFieldStyle(.roundedBorder)
          .frame(maxWidth: 200)
          .onSubmit(commitIp)
        Button {
          showDiscovery = true
        } label: {
          Label("Discover", systemImage: "wifi")
        }
        .help("Scan the local network for WiZ lights.")
        if app.connected {
          Button {
            app.disconnect()
          } label: {
            Label("Disconnect", systemImage: "wifi.slash")
          }
          .help("Stop controlling this light.")
        } else if app.hasLight {
          Button {
            app.reconnect()
          } label: {
            Label("Connect", systemImage: "link")
          }
          .help("Connect to this light and load its colour and brightness.")
        }
        Spacer()
        statusDot
      }
      if app.displayName != app.selectedIp {
        Text(app.displayName)
          .font(.subheadline)
          .foregroundStyle(.secondary)
      }
    }
    .onAppear { ipText = app.selectedIp }
    .onChange(of: app.selectedIp) { ipText = $0 }
    .sheet(isPresented: $showDiscovery) {
      DiscoveryView().environmentObject(app)
    }
  }

  private var statusDot: some View {
    HStack(spacing: 6) {
      Circle()
        .fill(app.connected ? Color.green : Color.red)
        .frame(width: 10, height: 10)
      Text(app.connected ? "Connected" : "Disconnected")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
  }

  private func commitIp() {
    let trimmed = ipText.trimmingCharacters(in: .whitespaces)
    guard app.core.isValidIp(trimmed) else { return }
    // Keep a matching saved light's name/MAC if we have one for this IP.
    if let (mac, light) = app.savedLights.first(where: { $0.value.ip == trimmed }) {
      app.selectLight(name: light.name, ip: trimmed, mac: mac)
    } else {
      app.selectLight(name: trimmed, ip: trimmed, mac: "")
    }
    // selectLight already attempts to connect.
  }
}

// MARK: - Power + mode

struct PowerModeBar: View {
  @EnvironmentObject var app: AppState

  var body: some View {
    HStack(spacing: 16) {
      Toggle(isOn: powerBinding) {
        Text(app.state.on ? "On" : "Off")
      }
      .toggleStyle(.switch)
      .disabled(!app.hasLight)

      if app.state.on {
        Picker("Mode", selection: modeBinding) {
          ForEach(AppState.ColorMode.allCases) { mode in
            Text(mode.label).tag(mode)
          }
        }
        .pickerStyle(.segmented)
        .frame(maxWidth: 280)
        .disabled(!app.hasLight)
      }
      Spacer()
    }
  }

  private var powerBinding: Binding<Bool> {
    Binding(get: { app.state.on }, set: { app.setPower($0) })
  }

  private var modeBinding: Binding<AppState.ColorMode> {
    Binding(get: { app.colorMode }, set: { app.setColorMode($0) })
  }
}

/// Warm Glow caption: in this mode you set only brightness and the colour
/// temperature auto-follows the bulb's dim-to-warm curve.
struct WarmGlowInfo: View {
  @EnvironmentObject var app: AppState

  var body: some View {
    HStack(spacing: 10) {
      Image(systemName: "flame.fill")
        .foregroundStyle(.orange)
      VStack(alignment: .leading, spacing: 2) {
        Text("Warm Glow").font(.subheadline.weight(.medium))
        Text("Colour temperature follows brightness — now ≈ \(app.state.temp) K")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Spacer()
    }
    .padding(.vertical, 4)
  }
}
