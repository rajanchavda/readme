import Foundation

/// Geometry of the page curl, matching the maths in `docs/mockups/open-book-v2.html`.
/// The turning page is a chain of `strips` hinged strips; `angles` gives each strip's
/// cumulative rotation in degrees.
enum CurlPose {
    static let duration = 0.52
    static let strips = 28
    static let bend = 34.0

    /// Cumulative angle in degrees for each strip at progress `t` in 0...1.
    static func angles(t: Double, strips: Int = strips, bend: Double = bend) -> [Double] {
        let e = t * t * (3 - 2 * t)
        let b = bend * sin(2 * Double.pi * t)
        let root = -180 * e + b
        let d = 2 * b / Double(strips - 1)
        return (0..<strips).map { k in
            max(-179.5, min(0, root - Double(k) * d))
        }
    }

    /// Darkness of the page face for a strip at `angle` degrees: darkest when edge-on.
    static func shade(angle: Double) -> Double {
        abs(sin(angle * Double.pi / 180)) * 0.16
    }

    /// Strength of the cast shadow at progress `t`, peaking at the midpoint.
    static func cast(t: Double) -> Double {
        sin(Double.pi * t)
    }
}
