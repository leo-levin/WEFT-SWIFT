// Projection3D.swift - 3D camera rotation and isometric projection for Loom

import SwiftUI
import simd

struct Camera3D {
    var yaw: Double = -0.4      // Rotation around Y axis (from drag)
    var pitch: Double = 0.3     // Rotation around X axis (from drag)
    var scale: Double = 0.7     // Viewport scale factor

    /// Project a 3D point to 2D screen coordinates (isometric — no perspective).
    func project(_ point: SIMD3<Double>, viewSize: CGSize) -> CGPoint {
        let rotated = rotateYX(point)
        let halfW = viewSize.width * 0.5
        let halfH = viewSize.height * 0.5
        let s = min(halfW, halfH) * scale
        return CGPoint(
            x: halfW + rotated.x * s,
            y: halfH - rotated.y * s
        )
    }

    /// Depth after rotation (for painter's algorithm sorting).
    func depth(_ point: SIMD3<Double>) -> Double {
        rotateYX(point).z
    }

    /// Apply yaw (around Y) then pitch (around X) rotation.
    private func rotateYX(_ p: SIMD3<Double>) -> SIMD3<Double> {
        // Yaw rotation (around Y axis)
        let cy = cos(yaw)
        let sy = sin(yaw)
        let afterYaw = SIMD3<Double>(
            p.x * cy + p.z * sy,
            p.y,
            -p.x * sy + p.z * cy
        )
        // Pitch rotation (around X axis)
        let cp = cos(pitch)
        let sp = sin(pitch)
        return SIMD3<Double>(
            afterYaw.x,
            afterYaw.y * cp - afterYaw.z * sp,
            afterYaw.y * sp + afterYaw.z * cp
        )
    }
}
