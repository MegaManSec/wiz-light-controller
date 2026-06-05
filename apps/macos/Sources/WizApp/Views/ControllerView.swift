import SwiftUI
import WizKit

/// The main controller UI hosted in the manual window. A tab view: live controls
/// (connection, power, colour, brightness, presets) and settings. Reads/writes
/// `AppState`; every edit routes through `applyLive()` (the engine/WizClient
/// already debounces).
struct ControllerView: View {
  @EnvironmentObject var app: AppState

  var body: some View {
    // A custom segmented header instead of a `TabView`: on macOS 26 the system
    // tab bar renders as a floating glass strip that overlaps the scroll content
    // beneath it. A plain segmented picker + switched content keeps the layout
    // fully under our control and matches the mode pickers used elsewhere.
    VStack(spacing: 0) {
      Picker("View", selection: tabBinding) {
        Text("Controls").tag(ControllerWindowController.Tab.controls)
        Text("Settings").tag(ControllerWindowController.Tab.settings)
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      .frame(maxWidth: 320)
      .padding(.horizontal, 20)
      .padding(.top, 12)
      .padding(.bottom, 10)

      Divider()

      switch app.selectedTab {
      case .controls: controls
      case .settings: SettingsView()
      }
    }
    .frame(minWidth: 600, minHeight: 500)
    .onAppear {
      // Refresh a connected light's values, but never reconnect a manually
      // disconnected one (matches the menu-bar popover's refreshIfConnected).
      if app.settings.autoSync, app.hasLight { app.refreshIfConnected() }
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
            .padding(.bottom, 10)
          // Colour controls stay visible even when off, so you can stage a colour
          // or mode and have it apply when you bring the brightness back up.
          if app.warmGlow {
            WarmGlowInfo()
          } else if app.state.mode == .rgb {
            ColorWheelView()
            SlidersView()
            WhiteMixToggle()
          } else {
            WhiteTempView()
          }
          // Brightness stays visible even when off (knob at 0) — slide up to turn
          // the light back on and set the level.
          BrightnessView()
          PresetsView()
        } else if app.hasLight {
          Label(
            "Not connected — press Connect to control \(app.displayName).",
            systemImage: "wifi.slash"
          )
          .foregroundStyle(.secondary)
          .padding(.top, 8)
        } else {
          Label(
            "No light selected. Choose a saved light above, or Discover one.",
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

// MARK: - Connection bar (saved-light picker + discover + status)

/// A saved-light dropdown (locked while connected), a Connect/Disconnect button, a
/// Discover button, and a live connection dot. Lights are added via Discover →
/// Save; you connect by choosing one here after disconnecting any current light.
struct ConnectionBar: View {
  @EnvironmentObject var app: AppState
  @State private var showDiscovery = false

  var body: some View {
    HStack(spacing: 8) {
      Text("Light")
      Picker("Light", selection: lightBinding) {
        Text(app.savedLights.isEmpty ? "No saved lights" : "Choose a light…").tag("")
        ForEach(app.savedLights.sorted { $0.value.name < $1.value.name }, id: \.key) { mac, light in
          Text(light.name).tag(mac)
        }
      }
      .labelsHidden()
      .frame(maxWidth: 200)
      .disabled(app.connected)
      .help("Choose a saved light, then Connect.")
      .overlay {
        // A disabled control doesn't surface its own tooltip, so when connected
        // overlay a transparent hover area explaining why it's locked.
        if app.connected {
          Color.clear.contentShape(Rectangle())
            .help("Disconnect before selecting lights.")
        }
      }

      if app.connected {
        Button {
          app.disconnect()
        } label: {
          Label("Disconnect", systemImage: "wifi.slash")
        }
        .help("Stop controlling this light.")
      } else {
        Button {
          app.reconnect()
        } label: {
          Label("Connect", systemImage: "link")
        }
        .disabled(!app.hasLight)
        .help("Connect to the selected light.")
      }

      Button {
        showDiscovery = true
      } label: {
        Label("Discover", systemImage: "wifi")
      }
      .help("Scan the local network for WiZ lights.")

      Spacer()
      statusDot
    }
    .sheet(isPresented: $showDiscovery) {
      DiscoveryView().environmentObject(app)
    }
    // The menu-bar popover's "Discover" CTA opens this window and sets a flag;
    // honour it whether the window was just built (onAppear) or already open
    // (onChange).
    .onAppear { consumeDiscoveryRequest() }
    .onChange(of: app.requestDiscovery) { _ in consumeDiscoveryRequest() }
  }

  /// Pop the discovery sheet if the popover asked for it, then clear the request.
  private func consumeDiscoveryRequest() {
    guard app.requestDiscovery else { return }
    app.requestDiscovery = false
    showDiscovery = true
  }

  /// The dropdown selects (without connecting) a saved light by MAC; the Connect
  /// button then connects to it.
  private var lightBinding: Binding<String> {
    Binding(
      get: { app.selectedMac },
      set: { mac in
        guard let light = app.savedLights[mac] else { return }
        app.selectLight(name: light.name, ip: light.ip, mac: mac, connect: false)
      })
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

      Picker("Mode", selection: modeBinding) {
        ForEach(AppState.ColorMode.allCases) { mode in
          Text(mode.label).tag(mode)
        }
      }
      .pickerStyle(.segmented)
      .frame(maxWidth: 280)
      .disabled(!app.hasLight)
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

/// RGB-only switch: blend a colour's white component into the bulb's bright white
/// LEDs for a noticeably brighter (slightly less saturated) result. Off keeps
/// colours faithful but dimmer — the colour LEDs alone.
struct WhiteMixToggle: View {
  @EnvironmentObject var app: AppState

  var body: some View {
    Toggle(isOn: Binding(get: { app.whiteMix }, set: { app.setWhiteMix($0) })) {
      VStack(alignment: .leading, spacing: 2) {
        Text("Brighter colours")
        Text("Uses the white LEDs to lift the colour — brighter, a little less saturated.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .toggleStyle(.switch)
    .padding(.top, 2)
  }
}
