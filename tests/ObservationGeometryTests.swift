import Foundation
import CoreGraphics

@main struct ObservationGeometryTests {
    static func main() {
        var checks = 0
        func check(_ value: Bool, _ label: String) { precondition(value, label); checks += 1 }
        let retina = ObservationGeometry(frame: CGRect(x: -1440, y: 120, width: 1440, height: 900), imageSize: CGSize(width: 2880, height: 1800))
        check(retina.screenPoint(x: 1440, y: 900) == CGPoint(x: -720, y: 570), "Retina pixels map to logical points on a left-hand monitor")
        let budgeted = ObservationGeometry(frame: retina.frame, imageSize: CGSize(width: 1080, height: 675))
        check(budgeted.screenPoint(x: 540, y: 337.5) == retina.screenPoint(x: 1440, y: 900), "JPEG downscaling preserves the same target")
        check(retina.screenPoint(x: 0, y: 0) == CGPoint(x: -1440, y: 120), "top-left coordinate convention")
        check(retina.screenPoint(x: -1, y: 0) == nil, "negative pixels refused")
        check(retina.screenPoint(x: 2880, y: 0) == nil, "right-edge pixels outside image refused")
        check(retina.screenPoint(x: 0, y: 1800) == nil, "bottom-edge pixels outside image refused")
        check(retina.screenPoint(x: .nan, y: 0) == nil && retina.screenPoint(x: 0, y: .infinity) == nil, "nonfinite coordinates refused")
        check(retina.matches(retina.frame), "unchanged exact window accepted")
        check(!retina.matches(retina.frame.offsetBy(dx: 3, dy: 0)), "moved same-app window refused")
        check(!retina.matches(CGRect(x: -1440, y: 120, width: 1500, height: 900)), "resized window refused")
        check(!retina.matches(CGRect(x: 0, y: 120, width: 1440, height: 900)), "other window of same dimensions refused")
        for size in [CGSize.zero, CGSize(width: -1, height: 100), CGSize(width: 100, height: CGFloat.infinity)] {
            check(ObservationGeometry(frame: retina.frame, imageSize: size).screenPoint(x: 0, y: 0) == nil, "invalid capture dimensions refused")
        }
        let patch = [UInt8](repeating: 120, count: 100)
        check(ObservationGeometry.visuallyMatches(patch, patch), "unchanged canvas patch accepted")
        check(ObservationGeometry.visuallyMatches(patch, [UInt8](repeating: 123, count: 100)), "minor capture noise tolerated")
        var changed = patch; changed[20] = 180; changed[21] = 180
        check(!ObservationGeometry.visuallyMatches(patch, changed), "changed target pixels refused even without AX changes")
        check(!ObservationGeometry.visuallyMatches([], []) && !ObservationGeometry.visuallyMatches(patch, [1]), "missing or incompatible visual evidence refused")
        let left = CGRect(x: 0, y: 0, width: 1000, height: 800), right = CGRect(x: 1200, y: 0, width: 1000, height: 800)
        let gap = CGRect(x: 1050, y: 100, width: 100, height: 100)
        check(left.union(right).intersects(gap), "the bounding box of two displays covers the gap between them")
        check(!ObservationGeometry.intersectsAnyDisplay(gap, displays: [left, right]), "an element wholly in the display gap is not visible")
        check(ObservationGeometry.intersectsAnyDisplay(CGRect(x: 950, y: 100, width: 150, height: 50), displays: [left, right]), "an element straddling a display edge is visible")
        check(!ObservationGeometry.intersectsAnyDisplay(CGRect(x: 1000, y: 0, width: 50, height: 50), displays: [left]), "touching an edge only is not visible")
        check(!ObservationGeometry.intersectsAnyDisplay(gap, displays: []), "no displays means nothing visible")
        print("PASS: \(checks) observation geometry checks")
    }
}
