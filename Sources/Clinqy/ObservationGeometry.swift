import Foundation
import CoreGraphics

/// Geometry belongs to the observation that produced an image, never to a process-global "last image".
/// Screen coordinates are logical points with a top-left origin; model coordinates are encoded-image pixels.
struct ObservationGeometry: Sendable {
    let frame: CGRect
    let imageSize: CGSize

    var isValid: Bool {
        [frame.minX, frame.minY, frame.width, frame.height, imageSize.width, imageSize.height].allSatisfy(\.isFinite)
            && frame.width > 0 && frame.height > 0 && imageSize.width > 0 && imageSize.height > 0
    }

    var pointScale: CGSize { CGSize(width: frame.width / imageSize.width, height: frame.height / imageSize.height) }

    func screenPoint(x: Double, y: Double) -> CGPoint? {
        guard isValid, x.isFinite, y.isFinite, x >= 0, y >= 0,
              x < imageSize.width, y < imageSize.height else { return nil }
        return CGPoint(x: frame.minX + x * pointScale.width, y: frame.minY + y * pointScale.height)
    }

    func matches(_ other: CGRect, tolerance: CGFloat = 0.5) -> Bool {
        guard isValid, [other.minX, other.minY, other.width, other.height].allSatisfy(\.isFinite) else { return false }
        return abs(frame.minX - other.minX) <= tolerance && abs(frame.minY - other.minY) <= tolerance
            && abs(frame.width - other.width) <= tolerance && abs(frame.height - other.height) <= tolerance
    }
    /// Whether any part of `frame` lies on an actual display. The bounding box of several monitors also covers
    /// the dead gaps between them, so visibility is decided display by display.
    static func intersectsAnyDisplay(_ frame: CGRect, displays: [CGRect]) -> Bool {
        displays.contains { display in
            let overlap = display.intersection(frame)
            return !overlap.isNull && overlap.width > 0 && overlap.height > 0
        }
    }

    /// Tolerate tiny capture noise, but not a changed icon, text label, canvas control or target position.
    static func visuallyMatches(_ old: [UInt8], _ current: [UInt8]) -> Bool {
        guard !old.isEmpty, old.count == current.count else { return false }
        let changed = zip(old, current).reduce(0) { $0 + (abs(Int($1.0) - Int($1.1)) > 8 ? 1 : 0) }
        return changed * 100 <= old.count
    }

}
