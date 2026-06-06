import SwiftUI

/// A horizontal slider whose track is an arbitrary gradient (so the RGB / HSV /
/// brightness / temperature sliders can tint their tracks by the live colour,
/// like the Python app). A white thumb tracks the value. Pure SwiftUI: a
/// `Canvas`-free rounded gradient rectangle plus a drag gesture mapping x →
/// value across `range`.
struct GradientSlider: View {
  @Binding var value: Double
  let range: ClosedRange<Double>
  /// Colour stops painted left→right across the track.
  let colors: [Color]
  /// When set, draw a solid progress track — `filled` left of the thumb, `unfilled`
  /// after it — instead of the gradient. Matches the popover's scene-speed slider.
  var progressFill: (filled: Color, unfilled: Color)? = nil
  /// Called continuously while dragging (after `value` updates) so callers can
  /// push the change to the light.
  var onEditing: () -> Void = {}
  /// Called once when the drag ends (mouse released).
  var onCommit: () -> Void = {}

  private let height: CGFloat = 18
  private let thumb: CGFloat = 16

  var body: some View {
    GeometryReader { geo in
      let width = geo.size.width
      let usable = max(1, width - thumb)
      let fraction = CGFloat((value - range.lowerBound) / max(0.0001, range.upperBound - range.lowerBound))
      let x = thumb / 2 + fraction * usable

      ZStack(alignment: .leading) {
        trackView(x: x)

        Circle()
          .fill(.white)
          .frame(width: thumb, height: thumb)
          .overlay(Circle().strokeBorder(.black.opacity(0.55), lineWidth: 1.5))
          .shadow(radius: 1)
          .position(x: x, y: height / 2)
      }
      .frame(height: height)
      .contentShape(Rectangle())
      .gesture(
        DragGesture(minimumDistance: 0)
          .onChanged { g in
            let clampedX = min(max(g.location.x - thumb / 2, 0), usable)
            let frac = clampedX / usable
            value = range.lowerBound + Double(frac) * (range.upperBound - range.lowerBound)
            onEditing()
          }
          .onEnded { _ in onCommit() })
    }
    .frame(height: height)
  }

  /// The track behind the thumb: a solid progress fill (filled left of the thumb
  /// centre `x`, unfilled after) when `progressFill` is set, else the gradient.
  @ViewBuilder
  private func trackView(x: CGFloat) -> some View {
    let border = RoundedRectangle(cornerRadius: height / 2).strokeBorder(.black.opacity(0.2), lineWidth: 1)
    if let pf = progressFill {
      ZStack(alignment: .leading) {
        Rectangle().fill(pf.unfilled)
        Rectangle().fill(pf.filled).frame(width: x)
      }
      .frame(height: height)
      .clipShape(RoundedRectangle(cornerRadius: height / 2))
      .overlay(border)
    } else {
      RoundedRectangle(cornerRadius: height / 2)
        .fill(LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing))
        .frame(height: height)
        .overlay(border)
    }
  }
}
