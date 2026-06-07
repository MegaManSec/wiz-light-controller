import Foundation

/// macOS-only presentation for each dynamic scene: an SF Symbol and a
/// representative tint, used to render the scene chips in the controls grid and
/// the menu-bar popover. Keyed by the engine's scene id.
///
/// This deliberately lives in the Swift layer, *not* the JS core — the CLI has no
/// icons, and SF Symbols are an Apple-only concept. Symbols are restricted to the
/// SF Symbols 4 set (shipped with our macOS 13 minimum) so none render blank on an
/// older OS; `symbol(_:)` falls back to a generic glyph for anything unmapped.
/// Tints are `[r, g, b]` triples to suit both SwiftUI `Color(rgb:)` and AppKit
/// `nsColor(_:)`. Like ``SCENE_HINTS`` they're **approximate** — they mirror each
/// scene's dominant colour, not device-reported data.
public enum SceneIcons {
  /// SF Symbol name for a scene id (generic `sparkles` for anything unmapped).
  public static func symbol(_ id: Int) -> String { table[id]?.symbol ?? "sparkles" }

  /// Representative tint `[r, g, b]` for a scene id (neutral grey when unmapped).
  public static func tint(_ id: Int) -> [Int] { table[id]?.tint ?? [150, 150, 150] }

  private static let table: [Int: (symbol: String, tint: [Int])] = [
    1: ("water.waves", [0, 150, 170]),  // Ocean
    2: ("heart", [220, 80, 110]),  // Romance
    3: ("sunset", [240, 130, 60]),  // Sunset
    4: ("party.popper", [230, 70, 160]),  // Party
    5: ("flame", [230, 110, 40]),  // Fireplace
    6: ("cup.and.saucer", [210, 150, 90]),  // Cozy
    7: ("tree", [60, 150, 80]),  // Forest
    8: ("circle.hexagongrid", [200, 150, 210]),  // Pastel Colors
    9: ("alarm", [240, 200, 120]),  // Wake-up
    10: ("moon.zzz", [150, 120, 170]),  // Bedtime
    11: ("lightbulb.fill", [240, 200, 150]),  // Warm White
    12: ("sun.max", [220, 215, 190]),  // Daylight
    13: ("snowflake", [180, 210, 240]),  // Cool White
    14: ("moon.stars", [120, 120, 160]),  // Night Light
    15: ("viewfinder", [120, 180, 230]),  // Focus
    16: ("leaf", [150, 180, 150]),  // Relax
    17: ("paintpalette", [170, 90, 200]),  // True Colors
    18: ("tv", [90, 110, 170]),  // TV Time
    19: ("camera.macro", [210, 70, 180]),  // Plantgrowth
    20: ("bird", [120, 190, 110]),  // Spring
    21: ("beach.umbrella", [250, 180, 60]),  // Summer
    22: ("wind", [200, 110, 50]),  // Fall
    23: ("fish", [30, 90, 180]),  // Deep-dive
    24: ("pawprint", [90, 160, 70]),  // Jungle
    25: ("wineglass", [150, 200, 90]),  // Mojito
    26: ("music.note", [150, 60, 200]),  // Club
    27: ("gift", [200, 50, 60]),  // Christmas
    28: ("theatermasks", [230, 120, 30]),  // Halloween
    29: ("flame.fill", [230, 150, 70]),  // Candlelight
    30: ("sun.haze", [230, 180, 90]),  // Golden White
    31: ("waveform", [80, 160, 220]),  // Pulse
    32: ("gearshape.2", [180, 130, 70]),  // Steampunk
    33: ("sparkles", [240, 160, 40]),  // Diwali
    34: ("lightbulb", [220, 220, 225]),  // White
    35: ("bell", [225, 90, 60]),  // Alarm
    36: ("cloud.snow", [170, 200, 235]),  // Snowy Sky
  ]
}

extension LightScene {
  /// SF Symbol name for this scene (see ``SceneIcons``).
  public var symbol: String { SceneIcons.symbol(id) }
  /// Representative tint as an `[r, g, b]` triple (see ``SceneIcons``).
  public var tint: [Int] { SceneIcons.tint(id) }
}
