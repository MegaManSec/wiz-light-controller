import Foundation

/// Persistence layer, using the exact on-disk schema of the wiz-light-core CLI
/// stores. **Note on location:** the released app runs under the App Sandbox, so
/// `.applicationSupportDirectory` resolves *inside its container*
/// (`~/Library/Containers/com.wizlightcontroller.app/Data/Library/Application
/// Support/WizLightController`) — not the CLI's `~/Library/Application
/// Support/WizLightController`. The two tools therefore keep the same format but
/// each owns its own copy; only an unsandboxed dev run (`swift run` /
/// `swift test`, no entitlements applied) lands in the CLI's directory. Reads
/// are corruption-tolerant (missing or malformed → defaults); writes are atomic
/// (temp file + `replaceItemAt`) so a crash mid-write can't truncate good data.
///
/// File map (mirrors `wiz-light-core` stores):
/// - `settings.json`     `{accent, highlight, autoSync}`
/// - `presets.json`      `{rgb:{name:preset}, white:{name:preset}}`
/// - `saved_lights.json` `{mac:{name, ip}}`
/// - `last_ip.txt`       plain text
/// - `device_rgb.json`   `{mac: {r, g, b}}` — per-device last colour
/// - `last_device.json`  `{ip, mac, moduleName, firmware, summary}` — app-only; remembered identity
public final class Stores {
  // MARK: - Settings model

  public struct Settings: Equatable {
    public var accent: String
    public var highlight: String
    public var autoSync: Bool
    public init(accent: String, highlight: String, autoSync: Bool) {
      self.accent = accent
      self.highlight = highlight
      self.autoSync = autoSync
    }
    /// Matches `wiz-light-core` `DEFAULT_SETTINGS`.
    public static let defaults = Settings(accent: "#7b2cbf", highlight: "#590a9d", autoSync: true)
  }

  /// A saved light, keyed by MAC in `saved_lights.json`.
  public struct SavedLight: Equatable {
    public var name: String
    public var ip: String
    public init(name: String, ip: String) {
      self.name = name
      self.ip = ip
    }
  }

  // MARK: - Location

  /// The app's data directory. Defaults to the shared cross-tool location;
  /// override (tests, portable use) by passing a directory.
  public let dir: URL

  public init(directory: URL? = nil) {
    if let directory = directory {
      self.dir = directory
    } else {
      let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
      self.dir = base.appendingPathComponent("WizLightController", isDirectory: true)
    }
  }

  private var settingsURL: URL { dir.appendingPathComponent("settings.json") }
  private var presetsURL: URL { dir.appendingPathComponent("presets.json") }
  private var savedLightsURL: URL { dir.appendingPathComponent("saved_lights.json") }
  private var lastIpURL: URL { dir.appendingPathComponent("last_ip.txt") }
  private var deviceRgbURL: URL { dir.appendingPathComponent("device_rgb.json") }
  private var lastDeviceURL: URL { dir.appendingPathComponent("last_device.json") }

  // MARK: - Settings

  public func loadSettings() -> Settings {
    guard let obj = readJSON(settingsURL) as? [String: Any] else { return .defaults }
    let d = Settings.defaults
    return Settings(
      accent: normalizeHex(obj["accent"], fallback: d.accent),
      highlight: normalizeHex(obj["highlight"], fallback: d.highlight),
      autoSync: (obj["autoSync"] as? NSNumber)?.boolValue ?? d.autoSync
    )
  }

  public func saveSettings(_ s: Settings) {
    writeJSON(
      ["accent": s.accent, "highlight": s.highlight, "autoSync": s.autoSync],
      to: settingsURL)
  }

  // MARK: - Presets

  /// Load presets grouped by mode, seeding from `defaults` (`WizCore.defaultPresets()`)
  /// when the file is absent or unreadable. Names sorted for stable UI ordering.
  public func loadPresets(defaults: [LightMode: [Preset]]) -> [LightMode: [Preset]] {
    guard let obj = readJSON(presetsURL) as? [String: Any] else { return defaults }
    var result: [LightMode: [Preset]] = [.rgb: [], .white: []]
    for mode in [LightMode.rgb, .white] {
      guard let group = obj[mode.rawValue] as? [String: Any] else { continue }
      result[mode] = group.compactMap { name, value -> Preset? in
        guard let js = value as? [String: Any] else { return nil }
        return Preset(name: name, js: js)
      }.sorted { $0.name < $1.name }
    }
    // If the file existed but a group was empty/missing, keep the file's intent
    // (an explicitly-empty group) rather than re-seeding from defaults.
    return result
  }

  public func savePresets(_ presets: [LightMode: [Preset]]) {
    var obj: [String: Any] = [:]
    for mode in [LightMode.rgb, .white] {
      var group: [String: Any] = [:]
      for preset in presets[mode] ?? [] { group[preset.name] = preset.jsObject }
      obj[mode.rawValue] = group
    }
    writeJSON(obj, to: presetsURL)
  }

  // MARK: - Saved lights

  public func loadSavedLights() -> [String: SavedLight] {
    guard let obj = readJSON(savedLightsURL) as? [String: Any] else { return [:] }
    var result: [String: SavedLight] = [:]
    for (mac, value) in obj {
      guard let entry = value as? [String: Any] else { continue }
      let name = entry["name"] as? String ?? mac
      let ip = entry["ip"] as? String ?? ""
      result[mac] = SavedLight(name: name, ip: ip)
    }
    return result
  }

  public func saveSavedLights(_ map: [String: SavedLight]) {
    var obj: [String: Any] = [:]
    for (mac, light) in map { obj[mac] = ["name": light.name, "ip": light.ip] }
    writeJSON(obj, to: savedLightsURL)
  }

  /// Update a known light's IP only when it actually changed (the discovery
  /// path: a saved MAC reappears on a new DHCP address). Returns the new map.
  @discardableResult
  public func updateSavedLightIp(mac: String, ip: String) -> [String: SavedLight] {
    var map = loadSavedLights()
    guard let existing = map[mac], existing.ip != ip else { return map }
    map[mac] = SavedLight(name: existing.name, ip: ip)
    saveSavedLights(map)
    return map
  }

  // MARK: - Last IP / RGB

  public func loadLastIp() -> String {
    (try? String(contentsOf: lastIpURL, encoding: .utf8))?
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
  }

  public func saveLastIp(_ ip: String) {
    let trimmed = ip.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    writeText(trimmed, to: lastIpURL)
  }

  /// Forget the remembered last-used IP (e.g. the selected light was removed).
  /// `saveLastIp("")` can't do this — it guards against empty writes — so this
  /// removes the file instead.
  public func clearLastIp() {
    try? FileManager.default.removeItem(at: lastIpURL)
  }

  /// The last colour remembered for `mac`, or `nil` when unknown — so the wheel
  /// can open on this specific light's colour and a white→RGB flip restores it.
  public func loadDeviceRgb(_ mac: String) -> [Int]? {
    guard !mac.isEmpty, let map = readJSON(deviceRgbURL) as? [String: Any],
      let obj = map[mac] as? [String: Any]
    else { return nil }
    let r = (obj["r"] as? NSNumber)?.intValue ?? 255
    let g = (obj["g"] as? NSNumber)?.intValue ?? 255
    let b = (obj["b"] as? NSNumber)?.intValue ?? 255
    return [clampByte(r), clampByte(g), clampByte(b)]
  }

  public func saveDeviceRgb(_ rgb: [Int], forMac mac: String) {
    guard !mac.isEmpty, rgb.count == 3 else { return }
    var map = (readJSON(deviceRgbURL) as? [String: Any]) ?? [:]
    map[mac] = ["r": clampByte(rgb[0]), "g": clampByte(rgb[1]), "b": clampByte(rgb[2])]
    writeJSON(map, to: deviceRgbURL)
  }

  // MARK: - Last device identity

  /// The bulb's identity (MAC / model / firmware) remembered for a host, so the
  /// menu header and Settings → Device can show it on launch — before, or
  /// without, a live connection. Stored alongside its IP and returned only when
  /// the IP still matches, so an identity left over from a different address
  /// (the IP changed, or `last_ip` was repointed) is ignored rather than shown
  /// against the wrong bulb.
  public func loadLastDevice(
    forIp ip: String
  ) -> (mac: String, moduleName: String, firmware: String, summary: String)? {
    guard let obj = readJSON(lastDeviceURL) as? [String: Any], obj["ip"] as? String == ip else {
      return nil
    }
    return (
      mac: obj["mac"] as? String ?? "",
      moduleName: obj["moduleName"] as? String ?? "",
      firmware: obj["firmware"] as? String ?? "",
      summary: obj["summary"] as? String ?? ""
    )
  }

  public func saveLastDevice(
    ip: String, mac: String, moduleName: String, firmware: String, summary: String
  ) {
    let trimmedIp = ip.trimmingCharacters(in: .whitespacesAndNewlines)
    // Need an IP to key on, and at least one identifying field worth keeping — so
    // a partial reply can't clobber a good record with an all-empty identity.
    guard !trimmedIp.isEmpty, !(mac.isEmpty && moduleName.isEmpty) else { return }
    writeJSON(
      [
        "ip": trimmedIp, "mac": mac, "moduleName": moduleName, "firmware": firmware,
        "summary": summary,
      ],
      to: lastDeviceURL)
  }

  // MARK: - Low-level IO

  private func readJSON(_ url: URL) -> Any? {
    guard let data = try? Data(contentsOf: url) else { return nil }
    return try? JSONSerialization.jsonObject(with: data)
  }

  /// Atomic JSON write: pretty-printed (2-space-ish via `.prettyPrinted`) with a
  /// trailing newline, matching the CLI's files. Failures are swallowed —
  /// persistence is best-effort.
  private func writeJSON(_ obj: Any, to url: URL) {
    guard let data = try? JSONSerialization.data(
      withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]
    ) else { return }
    var withNewline = data
    withNewline.append(0x0a)
    writeData(withNewline, to: url)
  }

  private func writeText(_ text: String, to url: URL) {
    writeData(Data(text.utf8), to: url)
  }

  /// Write to a sibling temp file, then `replaceItemAt` for atomicity.
  private func writeData(_ data: Data, to url: URL) {
    let fm = FileManager.default
    try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
    let tmp = dir.appendingPathComponent(".\(UUID().uuidString).tmp")
    do {
      try data.write(to: tmp, options: .atomic)
      if fm.fileExists(atPath: url.path) {
        _ = try fm.replaceItemAt(url, withItemAt: tmp)
      } else {
        try fm.moveItem(at: tmp, to: url)
      }
    } catch {
      try? fm.removeItem(at: tmp)
    }
  }

  // MARK: - Small helpers

  private func clampByte(_ n: Int) -> Int { max(0, min(255, n)) }

  /// Best-effort hex normalisation for loose stored values, without needing a
  /// `WizCore` instance here (Stores stays engine-free). Falls back when not a
  /// 6-digit hex string.
  private func normalizeHex(_ value: Any?, fallback: String) -> String {
    guard var s = value as? String else { return fallback }
    s = s.trimmingCharacters(in: .whitespaces)
    if !s.hasPrefix("#") { s = "#" + s }
    guard s.count == 7 else { return fallback }
    let hex = s.dropFirst()
    guard hex.allSatisfy({ $0.isHexDigit }) else { return fallback }
    return s.lowercased()
  }
}
