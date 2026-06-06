import XCTest

@testable import WizKit

/// Exercises the JavaScriptCore bridge against the real generated bundle — this
/// proves the shared wiz-light-core logic is loaded and callable from Swift, and that
/// the Swift↔JS marshalling round-trips correctly.
final class WizCoreTests: XCTestCase {
  private let core = WizCore()

  func testColourConversions() {
    XCTAssertEqual(core.hsvToRgb([0.5, 1, 1]), [0, 255, 255])
    XCTAssertEqual(core.rgbToHex([255, 0, 0]), "#ff0000")
    XCTAssertEqual(core.hexToRgb("#7b2cbf"), [123, 44, 191])
    XCTAssertNil(core.hexToRgb("not-a-colour"))
    XCTAssertEqual(core.kelvinToRgb(6500).count, 3)
    // Folding the bulb's white channels (normalise to full value, wash toward
    // white) matches the official app to the digit; no white channels => unchanged.
    XCTAssertEqual(core.perceivedRgb([255, 0, 65], c: 0, w: 0), [255, 0, 65])
    XCTAssertEqual(core.perceivedRgb([255, 0, 65], c: 0, w: 111), [255, 101, 140]) // FF658C
  }

  func testWheelGeometry() {
    XCTAssertNotNil(core.wheelToHS(x: 120, y: 120, size: 240))  // centre is valid
    XCTAssertNil(core.wheelToHS(x: 1000, y: 1000, size: 240))  // outside the wheel
  }

  func testValidation() {
    XCTAssertTrue(core.isValidIp("192.168.1.50"))
    XCTAssertFalse(core.isValidIp("999.1.1.1"))
    XCTAssertEqual(core.normalizeHex("ABCDEF", fallback: "#000000"), "#abcdef")
    XCTAssertEqual(core.formatMac("aabbccddeeff"), "AA:BB:CC:DD:EE:FF")
  }

  func testParsePilotInfersMode() {
    let rgb = core.parsePilot(["state": true, "dimming": 50, "r": 255, "g": 0, "b": 0])
    XCTAssertEqual(rgb?.mode, .rgb)
    XCTAssertEqual(rgb?.brightness, 50)
    XCTAssertEqual(rgb?.rgb, [255, 0, 0])

    let white = core.parsePilot(["state": true, "dimming": 80, "temp": 3000])
    XCTAssertEqual(white?.mode, .white)
    XCTAssertEqual(white?.temp, 3000)

    // A real getPilot reply (the captured strip: off, warm white) parses cleanly.
    let real = core.parsePilot(["mac": "aabbccddeeff", "state": false, "temp": 2700, "dimming": 100])
    XCTAssertEqual(real?.on, false)
    XCTAssertEqual(real?.mode, .white)
    XCTAssertEqual(real?.temp, 2700)
  }

  func testBuildSetPilotParams() {
    let on = LightState(on: true, mode: .rgb, rgb: [10, 20, 30], temp: 4000, brightness: 5)
    let p = core.buildSetPilotParams(on)
    XCTAssertEqual(JSNum.int(p["dimming"]), 10, "brightness clamps to the firmware-valid floor")
    XCTAssertEqual(JSNum.int(p["r"]), 10)

    let off = LightState(on: false, mode: .rgb, rgb: [1, 2, 3], temp: 4000, brightness: 50)
    let offParams = core.buildSetPilotParams(off)
    XCTAssertEqual((offParams["state"] as? NSNumber)?.boolValue, false)
    XCTAssertNil(offParams["dimming"])

    // Per-device bounds (e.g. a bulb reporting minDimLevel 20 and a 2700 K floor)
    // clamp the wire values tighter than the WiZ-standard defaults.
    let white = LightState(on: true, mode: .white, rgb: [0, 0, 0], temp: 2200, brightness: 5)
    let bounded = core.buildSetPilotParams(white, bounds: ["dimMin": 20, "tempMin": 2700, "tempMax": 6500])
    XCTAssertEqual(JSNum.int(bounded["dimming"]), 20)
    XCTAssertEqual(JSNum.int(bounded["temp"]), 2700)
  }

  func testDeviceConfigParsing() {
    // Shared engine parsers, marshalled Swift → JS → Swift through JavaScriptCore.
    let bounds = core.deviceBounds(["cctRange": [2700, 2700, 6500, 6500], "minDimLevel": 10])
    XCTAssertEqual(bounds.tempMin, 2700)
    XCTAssertEqual(bounds.tempMax, 6500)
    XCTAssertEqual(bounds.dimMin, 10)

    let curve = core.dimToWarmCurve([
      "dim2WarmPoints": [[4200, 100], [1800, 1], [2700, 50]]
    ])
    XCTAssertEqual(curve.map(\.kelvin), [1800, 2700, 4200])
    XCTAssertEqual(curve.map(\.brightness), [1, 50, 100])
  }

  func testScenes() {
    // Capabilities + scene catalogue, gated by the device's channels.
    let rgbModel: [String: Any] = [
      "pwmRanges": [0, 1000, 0, 1000, 0, 1000, 0, 1000, 0, 1000], "nowc": 2,
    ]
    XCTAssertTrue(core.deviceCapabilities(rgbModel).rgb)
    let scenes = core.scenesForDevice(rgbModel)
    XCTAssertEqual(scenes.count, 32)
    XCTAssertTrue(scenes.contains { $0.id == 4 && $0.name == "Party" })

    // A scene round-trips through the wire format and back.
    let state = LightState(
      on: true, mode: .rgb, rgb: [255, 255, 255], temp: 4000, brightness: 80,
      scene: SceneRef(id: 4, speed: 120))
    let p = core.buildSetPilotParams(state)
    XCTAssertEqual(JSNum.int(p["sceneId"]), 4)
    XCTAssertEqual(JSNum.int(p["speed"]), 120)

    let parsed = core.parsePilot(["state": true, "sceneId": 4, "speed": 120, "dimming": 80])
    XCTAssertEqual(parsed?.scene?.id, 4)
    XCTAssertEqual(parsed?.scene?.speed, 120)
  }

  func testPresets() {
    let presets = core.defaultPresets()
    XCTAssertFalse(presets[.rgb]?.isEmpty ?? true)
    XCTAssertFalse(presets[.white]?.isEmpty ?? true)

    var state = LightState(on: false, mode: .rgb, rgb: [0, 0, 0], temp: 4000, brightness: 100)
    let relax = Preset(name: "Relax", mode: .white, temp: 3000, brightness: 100)
    state = core.applyPreset(state, relax)
    XCTAssertEqual(state.mode, .white)
    XCTAssertEqual(state.temp, 3000)
    XCTAssertTrue(core.stateMatchesPreset(state, relax))
  }
}
