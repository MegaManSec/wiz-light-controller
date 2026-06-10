import AppKit
import SwiftUI
import WizKit

/// HSV colour wheel. The wheel bitmap is rendered once (per size) into an
/// `NSImage` by sampling `WizCore.hsvToRgb` across the disc — exactly the
/// Python app's approach, but going through the shared engine. A draggable
/// marker is positioned via `WizCore.hsToWheel` and dragging hit-tests via
/// `WizCore.wheelToHS`. Wrapped as an `NSViewRepresentable` for pixel-accurate
/// drawing and a precise drag gesture.
struct ColorWheelView: View {
  @EnvironmentObject var app: AppState
  private let size: CGFloat = 240

  var body: some View {
    HStack {
      Spacer()
      WheelRepresentable(app: app, rgb: app.state.rgb, size: size)
        .frame(width: size, height: size)
      Spacer()
    }
  }
}

private struct WheelRepresentable: NSViewRepresentable {
  let app: AppState
  /// The live colour, passed explicitly so SwiftUI re-runs `updateNSView` and
  /// repaints the marker whenever it changes — from the wheel, the RGB/HSV
  /// sliders, or the hex field.
  let rgb: [Int]
  let size: CGFloat

  func makeNSView(context: Context) -> WheelNSView {
    let view = WheelNSView(frame: NSRect(x: 0, y: 0, width: size, height: size))
    view.onPick = { [weak app] h, s in
      // h,s are 0–1 from the engine; keep current value (brightness slider owns V).
      guard let app = app else { return }
      let v = max(0.0001, app.hsv.v / 100)
      app.setHSV(h: h * 360, s: s * 100, v: v * 100)
    }
    return view
  }

  func updateNSView(_ view: WheelNSView, context: Context) {
    view.core = app.core
    view.size = size
    // Marker position from the live colour's hue/sat.
    let hsv = app.core.rgbToHsv(rgb)
    view.updateMarker(h: hsv[0], s: hsv[1])
  }
}

/// The drawing + interaction layer. Caches the wheel bitmap and only repaints
/// the marker on state changes.
final class WheelNSView: NSView {
  var core: WizCore?
  var size: CGFloat = 240 { didSet { if size != oldValue { cached = nil; needsDisplay = true } } }
  /// Called with hue/sat (0–1) on click/drag inside the disc.
  var onPick: ((Double, Double) -> Void)?

  private var cached: NSImage?
  private var markerH: Double = 0
  private var markerS: Double = 0

  override var isFlipped: Bool { true }  // top-left origin, matching the engine's wheel coords.

  func updateMarker(h: Double, s: Double) {
    if h != markerH || s != markerS {
      markerH = h
      markerS = s
      needsDisplay = true
    }
  }

  override func draw(_ dirtyRect: NSRect) {
    let img = cached ?? renderWheel()
    cached = img
    // Clip to a circle so the rim is smoothly anti-aliased instead of showing the
    // bitmap's stair-stepped edge, and interpolate the upscaled fill on Retina.
    // The marker is drawn after the clip is lifted so it can sit right on the rim.
    NSGraphicsContext.current?.saveGraphicsState()
    NSGraphicsContext.current?.imageInterpolation = .high
    NSBezierPath(ovalIn: bounds).addClip()
    img.draw(in: bounds)
    NSGraphicsContext.current?.restoreGraphicsState()
    drawMarker()
  }

  /// Render the disc once by sampling the engine's `hsvToRgb` per pixel. Pixels
  /// outside the radius are transparent. ~240² is cheap and only runs on resize.
  private func renderWheel() -> NSImage {
    guard let core = core else { return NSImage(size: bounds.size) }
    let dim = Int(size)
    var pixels = [UInt8](repeating: 0, count: dim * dim * 4)

    // Colour every pixel inside the disc; the circular edge is smoothed by the
    // anti-aliased clip in `draw`, so the bitmap itself needs no rim feathering.
    for y in 0..<dim {
      for x in 0..<dim {
        guard let hs = core.wheelToHS(x: Double(x), y: Double(y), size: size) else { continue }
        let rgb = core.hsvToRgb([hs.h, hs.s, 1.0])
        let i = (y * dim + x) * 4
        pixels[i] = UInt8(clamping: rgb[0])
        pixels[i + 1] = UInt8(clamping: rgb[1])
        pixels[i + 2] = UInt8(clamping: rgb[2])
        pixels[i + 3] = 255
      }
    }

    let cs = CGColorSpaceCreateDeviceRGB()
    let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
    // Both the context and makeImage() must run inside withUnsafeMutableBytes:
    // a pointer bridged via `&pixels` is only valid for the duration of that one
    // call, so holding the context past it would be undefined behaviour.
    let cg: CGImage? = pixels.withUnsafeMutableBytes { buf in
      guard let ctx = CGContext(
        data: buf.baseAddress, width: dim, height: dim, bitsPerComponent: 8,
        bytesPerRow: dim * 4, space: cs, bitmapInfo: info.rawValue)
      else { return nil }
      return ctx.makeImage()
    }
    guard let cg = cg else { return NSImage(size: bounds.size) }
    return NSImage(cgImage: cg, size: bounds.size)
  }

  /// White ring marker at the live colour's hue/sat, via the engine's mapping.
  private func drawMarker() {
    guard let core = core else { return }
    let pt = core.hsToWheel(h: markerH, s: markerS, size: size)
    let r: CGFloat = 7
    let rect = NSRect(x: pt.x - r, y: pt.y - r, width: r * 2, height: r * 2)
    let path = NSBezierPath(ovalIn: rect)
    NSColor.white.setFill()
    path.fill()
    NSColor.black.withAlphaComponent(0.7).setStroke()
    path.lineWidth = 2
    path.stroke()
  }

  // MARK: - Interaction

  override func mouseDown(with event: NSEvent) { pick(event) }
  override func mouseDragged(with event: NSEvent) { pick(event) }

  private func pick(_ event: NSEvent) {
    guard let core = core else { return }
    let raw = convert(event.locationInWindow, from: nil)
    // A drag that leaves the disc would otherwise return nil and freeze the
    // marker. Clamp it to just inside the rim so it keeps tracking the angle,
    // stuck at the outermost edge (full saturation), until the mouse comes back.
    let c = Double(size) / 2
    var x = Double(raw.x), y = Double(raw.y)
    let dx = x - c, dy = y - c
    let dist = (dx * dx + dy * dy).squareRoot()
    if dist > c - 0.5 {
      let f = (c - 0.5) / dist
      x = c + dx * f
      y = c + dy * f
    }
    guard let hs = core.wheelToHS(x: x, y: y, size: size) else { return }
    onPick?(hs.h, hs.s)
  }
}
