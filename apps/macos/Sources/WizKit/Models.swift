import Foundation

/// Bulb operating mode. Raw values match the engine's JS string union.
public enum LightMode: String, Codable, Equatable {
  case rgb
  case white
}

/// A reference to a running dynamic scene — its id and an optional animation speed.
/// Mirrors the engine `LightState.scene`.
public struct SceneRef: Equatable {
  public var id: Int
  public var speed: Int?
  public init(id: Int, speed: Int? = nil) {
    self.id = id
    self.speed = speed
  }
}

/// A catalogue entry from the engine's scene table — an id and its display name.
/// (`LightScene`, not `Scene`, to avoid colliding with SwiftUI's `Scene`.)
public struct LightScene: Identifiable, Equatable {
  public let id: Int
  public let name: String
  public init(id: Int, name: String) {
    self.id = id
    self.name = name
  }
}

/// The light's logical state — the Swift mirror of wiz-light-core's `LightState`.
/// Marshalled to/from the JS engine as a plain dictionary.
public struct LightState: Equatable {
  public var on: Bool
  public var mode: LightMode
  public var rgb: [Int]  // three channels, 0–255
  public var temp: Int  // Kelvin
  public var brightness: Int  // 0–100
  public var scene: SceneRef?  // set only while a dynamic scene runs

  public init(
    on: Bool, mode: LightMode, rgb: [Int], temp: Int, brightness: Int, scene: SceneRef? = nil
  ) {
    self.on = on
    self.mode = mode
    self.rgb = rgb
    self.temp = temp
    self.brightness = brightness
    self.scene = scene
  }

  /// Plain dictionary form passed to the JS engine. `scene` is included only when
  /// set, so `buildSetPilotParams` emits a scene only when one is active.
  public var jsObject: [String: Any] {
    var o: [String: Any] = [
      "on": on, "mode": mode.rawValue, "rgb": rgb, "temp": temp, "brightness": brightness,
    ]
    if let scene = scene {
      var s: [String: Any] = ["id": scene.id]
      if let speed = scene.speed { s["speed"] = speed }
      o["scene"] = s
    }
    return o
  }

  /// Reconstruct from the engine's returned object (NSNumber/NSString-backed).
  public init?(js: [String: Any]) {
    guard let modeRaw = js["mode"] as? String, let mode = LightMode(rawValue: modeRaw) else {
      return nil
    }
    self.on = (js["on"] as? NSNumber)?.boolValue ?? false
    self.mode = mode
    self.rgb = JSNum.intArray(js["rgb"]) ?? [255, 255, 255]
    self.temp = JSNum.int(js["temp"]) ?? 4000
    self.brightness = JSNum.int(js["brightness"]) ?? 100
    if let s = js["scene"] as? [String: Any], let id = JSNum.int(s["id"]) {
      self.scene = SceneRef(id: id, speed: JSNum.int(s["speed"]))
    } else {
      self.scene = nil
    }
  }
}

/// A stored preset — RGB (`r`/`g`/`b`) or white (`temp`), plus a brightness.
public struct Preset: Equatable, Identifiable {
  public var name: String
  public var mode: LightMode
  public var r: Int?
  public var g: Int?
  public var b: Int?
  public var temp: Int?
  public var brightness: Int

  public var id: String { "\(mode.rawValue):\(name)" }

  public var jsObject: [String: Any] {
    var o: [String: Any] = ["mode": mode.rawValue, "brightness": brightness]
    if mode == .rgb {
      o["r"] = r ?? 0
      o["g"] = g ?? 0
      o["b"] = b ?? 0
    } else {
      o["temp"] = temp ?? 4000
    }
    return o
  }

  public init(name: String, js: [String: Any]) {
    self.name = name
    self.mode = LightMode(rawValue: js["mode"] as? String ?? "rgb") ?? .rgb
    self.r = JSNum.int(js["r"])
    self.g = JSNum.int(js["g"])
    self.b = JSNum.int(js["b"])
    self.temp = JSNum.int(js["temp"])
    self.brightness = JSNum.int(js["brightness"]) ?? 100
  }

  public init(
    name: String, mode: LightMode, r: Int? = nil, g: Int? = nil, b: Int? = nil, temp: Int? = nil,
    brightness: Int
  ) {
    self.name = name
    self.mode = mode
    self.r = r
    self.g = g
    self.b = b
    self.temp = temp
    self.brightness = brightness
  }
}

/// Narrow helpers for the loose `Any` values JavaScriptCore hands back
/// (everything arrives as `NSNumber`).
enum JSNum {
  static func int(_ v: Any?) -> Int? { (v as? NSNumber)?.intValue }
  static func double(_ v: Any?) -> Double? { (v as? NSNumber)?.doubleValue }
  static func intArray(_ v: Any?) -> [Int]? {
    (v as? [Any])?.compactMap { ($0 as? NSNumber)?.intValue }
  }
  static func doubleArray(_ v: Any?) -> [Double]? {
    (v as? [Any])?.compactMap { ($0 as? NSNumber)?.doubleValue }
  }
}
