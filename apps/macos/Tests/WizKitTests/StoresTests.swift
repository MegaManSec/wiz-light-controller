import XCTest

@testable import WizKit

/// Exercises the persistence layer against a throwaway temp directory, proving
/// the on-disk schema round-trips and that corrupt / missing files degrade to
/// defaults rather than throwing.
final class StoresTests: XCTestCase {
  private var dir: URL!
  private var stores: Stores!

  override func setUpWithError() throws {
    dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("wiz-stores-tests-\(UUID().uuidString)", isDirectory: true)
    stores = Stores(directory: dir)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: dir)
  }

  func testSettingsRoundTrip() {
    XCTAssertEqual(stores.loadSettings(), .defaults, "absent file → defaults")
    let custom = Stores.Settings(accent: "#112233", highlight: "#445566", autoSync: false)
    stores.saveSettings(custom)
    XCTAssertEqual(stores.loadSettings(), custom)
  }

  func testCorruptSettingsFallsBackToDefaults() throws {
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try Data("{ not json".utf8).write(to: dir.appendingPathComponent("settings.json"))
    XCTAssertEqual(stores.loadSettings(), .defaults)
  }

  func testSavedLightsRoundTripAndIpUpdate() {
    XCTAssertTrue(stores.loadSavedLights().isEmpty)
    stores.saveSavedLights(["aabbccddeeff": .init(name: "Desk", ip: "192.168.1.5")])
    XCTAssertEqual(stores.loadSavedLights()["aabbccddeeff"], .init(name: "Desk", ip: "192.168.1.5"))

    // IP only updates when it actually changed.
    let unchanged = stores.updateSavedLightIp(mac: "aabbccddeeff", ip: "192.168.1.5")
    XCTAssertEqual(unchanged["aabbccddeeff"]?.ip, "192.168.1.5")
    let updated = stores.updateSavedLightIp(mac: "aabbccddeeff", ip: "192.168.1.9")
    XCTAssertEqual(updated["aabbccddeeff"]?.ip, "192.168.1.9")
    XCTAssertEqual(updated["aabbccddeeff"]?.name, "Desk", "rename must survive an IP update")
  }

  func testLastIp() {
    XCTAssertEqual(stores.loadLastIp(), "")
    stores.saveLastIp("  10.0.0.42  ")
    XCTAssertEqual(stores.loadLastIp(), "10.0.0.42", "trims surrounding whitespace")
  }

  func testDeviceRgbIsPerMacAndClamped() {
    let mac = "aabbccddeeff"
    XCTAssertNil(stores.loadDeviceRgb(mac), "absent → nil")
    stores.saveDeviceRgb([10, 20, 300], forMac: mac)
    XCTAssertEqual(
      stores.loadDeviceRgb(mac), [10, 20, 255], "out-of-range channels clamp to a byte")
    // Each device keeps its own colour memory.
    XCTAssertNil(stores.loadDeviceRgb("001122334455"), "a different MAC has no colour yet")
    // An empty MAC is never keyed.
    stores.saveDeviceRgb([1, 2, 3], forMac: "")
    XCTAssertNil(stores.loadDeviceRgb(""), "empty MAC → nil")
  }

  func testLastDeviceRoundTripAndIpGuard() {
    XCTAssertNil(stores.loadLastDevice(forIp: "192.168.1.50"), "absent → nil")

    stores.saveLastDevice(
      ip: "  192.168.1.50  ", mac: "aabbccddeeff", moduleName: "ESP20_SHRGB_01ABI",
      firmware: "1.37.0", summary: "RGB + tunable white 2700–6500 K")
    let id = stores.loadLastDevice(forIp: "192.168.1.50")
    XCTAssertEqual(id?.mac, "aabbccddeeff")
    XCTAssertEqual(id?.moduleName, "ESP20_SHRGB_01ABI", "round-trips the model name")
    XCTAssertEqual(id?.firmware, "1.37.0")
    XCTAssertEqual(id?.summary, "RGB + tunable white 2700–6500 K", "round-trips the summary")

    // The identity is only returned for the IP it was saved against — a stale one
    // from a different address (IP changed, or the CLI repointed last_ip) is
    // ignored rather than shown against the wrong bulb.
    XCTAssertNil(stores.loadLastDevice(forIp: "192.168.1.99"), "different IP → ignored")

    // An all-empty identity is never persisted, so a partial reply can't clobber
    // a good record.
    stores.saveLastDevice(ip: "192.168.1.50", mac: "", moduleName: "", firmware: "", summary: "")
    XCTAssertEqual(
      stores.loadLastDevice(forIp: "192.168.1.50")?.moduleName, "ESP20_SHRGB_01ABI",
      "an empty identity doesn't clobber the stored one")
  }

  func testPresetsSeedFromDefaultsThenRoundTrip() {
    let core = WizCore()
    let defaults = core.defaultPresets()
    XCTAssertEqual(stores.loadPresets(defaults: defaults).keys.count, 2, "absent → seeded defaults")

    let presets: [LightMode: [Preset]] = [
      .rgb: [Preset(name: "Hot Pink", mode: .rgb, r: 255, g: 0, b: 128, brightness: 80)],
      .white: [Preset(name: "Candle", mode: .white, temp: 2200, brightness: 30)],
    ]
    stores.savePresets(presets)
    let loaded = stores.loadPresets(defaults: defaults)
    XCTAssertEqual(loaded[.rgb], presets[.rgb])
    XCTAssertEqual(loaded[.white], presets[.white])
  }
}
