import AppKit

/// A horizontal gradient slider sized to live inside an `NSMenuItem`'s view: a
/// rounded gradient track plus a draggable white knob. Reports continuous
/// changes through `onChange`. NSMenu keeps the menu open while it's dragged, so
/// the bulb follows the drag live. The gradient track shows the actual output —
/// brightness ramps toward the live colour, hue is a rainbow, temperature is a
/// warm→cool ramp — so you see what you're choosing.
final class MenuSlider: NSView {
  var minValue: Double = 0
  var maxValue: Double = 100
  var value: Double = 0 { didSet { needsDisplay = true } }
  var gradient: NSGradient?
  var onChange: ((Double) -> Void)?

  private let knobRadius: CGFloat = 6.5
  private let trackHeight: CGFloat = 5

  override func draw(_ dirtyRect: NSRect) {
    let inset = knobRadius + 1
    let usable = bounds.width - inset * 2
    let track = NSRect(
      x: inset, y: (bounds.height - trackHeight) / 2, width: usable, height: trackHeight)
    let trackPath = NSBezierPath(
      roundedRect: track, xRadius: trackHeight / 2, yRadius: trackHeight / 2)

    NSGraphicsContext.current?.saveGraphicsState()
    trackPath.addClip()
    if let gradient {
      gradient.draw(in: track, angle: 0)
    } else {
      NSColor.tertiaryLabelColor.setFill()
      track.fill()
    }
    NSGraphicsContext.current?.restoreGraphicsState()

    let t = CGFloat((value - minValue) / Swift.max(0.0001, maxValue - minValue))
    let cx = inset + t * usable
    let knob = NSRect(
      x: cx - knobRadius, y: bounds.height / 2 - knobRadius, width: knobRadius * 2,
      height: knobRadius * 2)
    let knobPath = NSBezierPath(ovalIn: knob)
    NSColor.white.setFill()
    knobPath.fill()
    NSColor.black.withAlphaComponent(0.25).setStroke()
    knobPath.lineWidth = 1
    knobPath.stroke()
  }

  override func mouseDown(with event: NSEvent) { update(with: event) }
  override func mouseDragged(with event: NSEvent) { update(with: event) }

  private func update(with event: NSEvent) {
    let inset = knobRadius + 1
    let usable = Swift.max(1, bounds.width - inset * 2)
    let x = convert(event.locationInWindow, from: nil).x
    let t = Swift.max(0, Swift.min(1, (x - inset) / usable))
    value = minValue + Double(t) * (maxValue - minValue)
    onChange?(value)
  }
}
