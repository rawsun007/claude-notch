import SwiftUI

/// The hanging-notch shape used by Dynamic-Island-style apps. Unlike a plain
/// rounded rectangle, the TOP corners are *concave* fillets: the shape spans
/// the full width at the very top edge and curves inward as it descends, so
/// it reads as an extension of the menu-bar / physical notch rather than a
/// detached card. The bottom corners are normal convex rounds.
///
/// Both radii are animatable, so growing/shrinking the frame while morphing
/// the radii gives the smooth "grows out of the notch" motion.
/// (Algorithm originates from DynamicNotchKit, MIT-licensed.)
struct NotchShape: Shape {
    var topCornerRadius: CGFloat
    var bottomCornerRadius: CGFloat

    init(topCornerRadius: CGFloat = 8, bottomCornerRadius: CGFloat = 14) {
        self.topCornerRadius = topCornerRadius
        self.bottomCornerRadius = bottomCornerRadius
    }

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { .init(topCornerRadius, bottomCornerRadius) }
        set {
            topCornerRadius = newValue.first
            bottomCornerRadius = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        let t = max(0, topCornerRadius)
        let b = max(0, bottomCornerRadius)
        var path = Path()

        // Top-left: start at the very top edge, curve down + inward (concave).
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + t, y: rect.minY + t),
            control: CGPoint(x: rect.minX + t, y: rect.minY)
        )

        // Left wall down to where the bottom-left round begins.
        path.addLine(to: CGPoint(x: rect.minX + t, y: rect.maxY - b))

        // Bottom-left convex round.
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + t + b, y: rect.maxY),
            control: CGPoint(x: rect.minX + t, y: rect.maxY)
        )

        // Bottom edge.
        path.addLine(to: CGPoint(x: rect.maxX - t - b, y: rect.maxY))

        // Bottom-right convex round.
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX - t, y: rect.maxY - b),
            control: CGPoint(x: rect.maxX - t, y: rect.maxY)
        )

        // Right wall up.
        path.addLine(to: CGPoint(x: rect.maxX - t, y: rect.minY + t))

        // Top-right: curve up + outward to the top edge (concave).
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY),
            control: CGPoint(x: rect.maxX - t, y: rect.minY)
        )

        // Close along the top edge.
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
        path.closeSubpath()
        return path
    }
}
