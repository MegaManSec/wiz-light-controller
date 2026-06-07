import Foundation
import JavaScriptCore

/// Bridge to the shared wiz-light-core engine. Loads the bundled IIFE
/// (`wiz-core.global.js`, generated from the pure colour + model + validate
/// modules) into a JavaScriptCore context and exposes typed Swift wrappers — so
/// the macOS app and the CLI share one tested implementation of the colour maths
/// and the light-state model.
///
/// `JSContext` is not thread-safe; use a `WizCore` instance from a single thread
/// (the app uses it on the main actor).
public final class WizCore {
  private let core: JSValue

  public init() {
    guard let context = JSContext() else { fatalError("Could not create JSContext") }
    context.exceptionHandler = { _, exception in
      let message = exception?.toString() ?? "unknown"
      FileHandle.standardError.write(Data("WizCore JS exception: \(message)\n".utf8))
    }
    context.evaluateScript(Self.loadBundle())
    guard let core = context.objectForKeyedSubscript("WizCore"), !core.isUndefined else {
      fatalError("WizCore global not found in bundle")
    }
    self.core = core
  }

  /// The generated bundle ships in the app's `Resources` (found via `Bundle.main`
  /// once assembled into the `.app`) and in the SwiftPM resource bundle (found via
  /// `Bundle.module` under `swift test`).
  ///
  /// `Bundle.main` is tried first and `Bundle.module` is only *evaluated* if that
  /// misses: SwiftPM's generated `Bundle.module` accessor `fatalError`s when the
  /// resource bundle isn't at the path it expects (which it isn't inside an
  /// assembled `.app`, where the resource lives in `Contents/Resources`). Eagerly
  /// referencing it — e.g. in an array literal — would crash the app before
  /// `Bundle.main` ever got a look.
  private static func loadBundle() -> String {
    if let source = source(in: Bundle.main) { return source }
    if let source = source(in: Bundle.module) { return source }
    fatalError("wiz-core.global.js not found in app or module bundle")
  }

  private static func source(in bundle: Bundle) -> String? {
    guard let url = bundle.url(forResource: "wiz-core.global", withExtension: "js") else {
      return nil
    }
    return try? String(contentsOf: url, encoding: .utf8)
  }

  private func call(_ fn: String, _ args: [Any]) -> JSValue {
    // `invokeMethod` returns an implicitly-unwrapped JSValue; for an existing
    // engine function it is never nil.
    core.invokeMethod(fn, withArguments: args)
  }

  // MARK: - Colour

  public func hsvToRgb(_ hsv: [Double]) -> [Int] { JSNum.intArray(call("hsvToRgb", [hsv]).toArray()) ?? [0, 0, 0] }
  public func rgbToHsv(_ rgb: [Int]) -> [Double] { JSNum.doubleArray(call("rgbToHsv", [rgb]).toArray()) ?? [0, 0, 0] }
  public func rgbToHex(_ rgb: [Int]) -> String { call("rgbToHex", [rgb]).toString() ?? "#ffffff" }
  public func hexToRgb(_ hex: String) -> [Int]? {
    let v = call("hexToRgb", [hex])
    return (v.isNull || v.isUndefined) ? nil : JSNum.intArray(v.toArray())
  }
  public func kelvinToRgb(_ kelvin: Int) -> [Int] { JSNum.intArray(call("kelvinToRgb", [kelvin]).toArray()) ?? [255, 255, 255] }

  /// Fold the bulb's white channels (`c`/`w`) into an RGB triple to approximate
  /// the colour the eye sees — `parsePilot` reports r/g/b only, so a colour the
  /// bulb renders with its white LEDs reads back over-saturated. Display only;
  /// see color.js `perceivedRgb`.
  public func perceivedRgb(_ rgb: [Int], c: Int, w: Int) -> [Int] {
    JSNum.intArray(call("perceivedRgb", [rgb, c, w]).toArray()) ?? rgb
  }

  /// Wheel point → hue/saturation, or `nil` outside the wheel.
  public func wheelToHS(x: Double, y: Double, size: Double) -> (h: Double, s: Double)? {
    let v = call("wheelToHS", [x, y, size])
    guard !v.isNull, !v.isUndefined, let d = v.toDictionary() as? [String: Any],
      let h = JSNum.double(d["h"]), let s = JSNum.double(d["s"])
    else { return nil }
    return (h, s)
  }

  public func hsToWheel(h: Double, s: Double, size: Double) -> (x: Double, y: Double) {
    let d = call("hsToWheel", [h, s, size]).toDictionary() as? [String: Any] ?? [:]
    return (JSNum.double(d["x"]) ?? 0, JSNum.double(d["y"]) ?? 0)
  }

  // MARK: - Validation

  public func isValidIp(_ value: String) -> Bool { call("isValidIp", [value]).toBool() }
  public func normalizeHex(_ value: String, fallback: String) -> String {
    call("normalizeHex", [value, fallback]).toString() ?? fallback
  }
  public func formatMac(_ mac: String) -> String { call("formatMac", [mac]).toString() ?? mac }
  public func clampBrightness(_ n: Int) -> Int { Int(call("clampBrightness", [n]).toInt32()) }
  public func clampTemp(_ k: Int) -> Int { Int(call("clampTemp", [k]).toInt32()) }
  public func clampSpeed(_ n: Int) -> Int { Int(call("clampSpeed", [n]).toInt32()) }

  // MARK: - Model

  /// Interpret a `getPilot` result; `nil` when unusable.
  public func parsePilot(_ result: [String: Any]) -> LightState? {
    let v = call("parsePilot", [result])
    guard !v.isNull, !v.isUndefined, let d = v.toDictionary() as? [String: Any] else { return nil }
    return LightState(js: d)
  }

  /// Build the `setPilot` params for a desired state (`{ state: false }` when off).
  /// `whiteMix` (RGB only) routes a colour's achromatic part to the bulb's bright
  /// white channels (`c`/`w`) — brighter, slightly less saturated; see model.js.
  public func buildSetPilotParams(
    _ state: LightState, bounds: [String: Any] = [:], whiteMix: Bool = false
  ) -> [String: Any] {
    call("buildSetPilotParams", [state.jsObject, bounds, ["whiteMix": whiteMix]])
      .toDictionary() as? [String: Any] ?? [:]
  }

  /// Per-device send bounds parsed from a `getModelConfig` result, via the shared
  /// engine — the same parser the CLI uses.
  public func deviceBounds(_ modelConfig: [String: Any]) -> (tempMin: Int?, tempMax: Int?, dimMin: Int?) {
    let d = call("deviceBoundsFromConfig", [modelConfig]).toDictionary() as? [String: Any] ?? [:]
    return (JSNum.int(d["tempMin"]), JSNum.int(d["tempMax"]), JSNum.int(d["dimMin"]))
  }

  /// A short capability summary parsed from a `getModelConfig` result — e.g.
  /// "RGB + tunable white 2700–6500 K" — via the shared engine. Empty when the
  /// device doesn't report enough to tell.
  public func describeDevice(_ modelConfig: [String: Any]) -> String {
    call("describeDevice", [modelConfig]).toString() ?? ""
  }

  /// The device's colour capabilities from a `getModelConfig` result (shared engine) —
  /// used to decide whether to offer scenes.
  public func deviceCapabilities(_ modelConfig: [String: Any]) -> (
    rgb: Bool, tunableWhite: Bool, white: Bool
  ) {
    let d = call("deviceCapabilities", [modelConfig]).toDictionary() as? [String: Any] ?? [:]
    return (
      (d["rgb"] as? NSNumber)?.boolValue ?? false,
      (d["tunableWhite"] as? NSNumber)?.boolValue ?? false,
      (d["white"] as? NSNumber)?.boolValue ?? false
    )
  }

  /// The dynamic scenes a device can show, from a `getModelConfig` result (shared engine).
  public func scenesForDevice(_ modelConfig: [String: Any]) -> [LightScene] {
    guard let raw = call("scenesForDevice", [modelConfig]).toArray() else { return [] }
    return raw.compactMap { item in
      guard let d = item as? [String: Any], let id = JSNum.int(d["id"]),
        let name = d["name"] as? String
      else { return nil }
      return LightScene(id: id, name: name, hint: d["hint"] as? String ?? "")
    }
  }

  /// Dim-to-warm curve parsed from a `getUserConfig` result, via the shared engine.
  public func dimToWarmCurve(_ userConfig: [String: Any]) -> [(kelvin: Int, brightness: Int)] {
    guard let raw = call("dimToWarmCurveFromConfig", [userConfig]).toArray() else { return [] }
    return raw.compactMap { item in
      guard let d = item as? [String: Any], let k = JSNum.int(d["kelvin"]),
        let b = JSNum.int(d["brightness"])
      else { return nil }
      return (kelvin: k, brightness: b)
    }
  }

  /// Brightness → Kelvin for Warm Glow, computed by the shared engine.
  public func warmGlowKelvin(
    _ brightness: Int, curve: [(kelvin: Int, brightness: Int)], range: ClosedRange<Int>
  ) -> Int {
    let jsCurve = curve.map { ["kelvin": $0.kelvin, "brightness": $0.brightness] }
    let jsRange: [String: Any] = ["min": range.lowerBound, "max": range.upperBound]
    return Int(call("warmGlowKelvin", [brightness, jsCurve, jsRange]).toInt32())
  }

  public func applyPreset(_ state: LightState, _ preset: Preset) -> LightState {
    let d = call("applyPreset", [state.jsObject, preset.jsObject]).toDictionary() as? [String: Any]
    return d.flatMap { LightState(js: $0) } ?? state
  }

  public func stateMatchesPreset(_ state: LightState, _ preset: Preset) -> Bool {
    call("stateMatchesPreset", [state.jsObject, preset.jsObject]).toBool()
  }

  // MARK: - Defaults

  public var defaultState: LightState {
    let d = core.objectForKeyedSubscript("DEFAULT_STATE").toDictionary() as? [String: Any] ?? [:]
    return LightState(js: d) ?? LightState(on: false, mode: .rgb, rgb: [255, 255, 255], temp: 4000, brightness: 100)
  }

  public var tempRange: ClosedRange<Int> {
    // TEMP_MIN/MAX live in the engine (color.js) — the single source of truth, and
    // are always defined (init() fatalErrors if the bundle failed to load), so use
    // them directly rather than re-hardcoding the 2200/6500 literals here.
    let lo = Int(core.objectForKeyedSubscript("TEMP_MIN").toInt32())
    let hi = Int(core.objectForKeyedSubscript("TEMP_MAX").toInt32())
    return lo...hi
  }

  /// The seeded presets, grouped `rgb` / `white`, preserving insertion order.
  public func defaultPresets() -> [LightMode: [Preset]] {
    let groups = core.objectForKeyedSubscript("DEFAULT_PRESETS")
    var result: [LightMode: [Preset]] = [.rgb: [], .white: []]
    for mode in [LightMode.rgb, .white] {
      let group = groups?.objectForKeyedSubscript(mode.rawValue)
      guard let dict = group?.toDictionary() as? [String: Any] else { continue }
      result[mode] = dict.map { Preset(name: $0.key, js: $0.value as? [String: Any] ?? [:]) }
        .sorted { $0.name < $1.name }
    }
    return result
  }
}
