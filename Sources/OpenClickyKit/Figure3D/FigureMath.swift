import Foundation
import simd

/// Small linear-algebra helpers for figures. Right-handed world, y up, z toward the viewer; Metal clip depth 0...1.
public enum FigureMath {
    public static func radians(_ degrees: Float) -> Float { degrees * .pi / 180 }
    public static func degrees(_ radians: Float) -> Float { radians * 180 / .pi }

    public static func translation(_ t: SIMD3<Float>) -> simd_float4x4 {
        var m = matrix_identity_float4x4
        m.columns.3 = SIMD4(t, 1)
        return m
    }

    public static func scale(_ s: SIMD3<Float>) -> simd_float4x4 {
        simd_float4x4(diagonal: SIMD4(s, 1))
    }

    /// Euler angles in degrees applied X, then Y, then Z: matrix = Rx · Ry · Rz (the figure language's convention).
    public static func quaternion(eulerDegrees e: SIMD3<Float>) -> simd_quatf {
        let qx = simd_quatf(angle: radians(e.x), axis: [1, 0, 0])
        let qy = simd_quatf(angle: radians(e.y), axis: [0, 1, 0])
        let qz = simd_quatf(angle: radians(e.z), axis: [0, 0, 1])
        return qx * qy * qz
    }

    public static func perspective(fovY: Float, aspect: Float, near: Float, far: Float) -> simd_float4x4 {
        let y = 1 / tan(fovY / 2)
        let x = y / aspect
        let z = far / (near - far)
        return simd_float4x4(columns: (SIMD4(x, 0, 0, 0), SIMD4(0, y, 0, 0), SIMD4(0, 0, z, -1), SIMD4(0, 0, z * near, 0)))
    }

    public static func orthographic(left: Float, right: Float, bottom: Float, top: Float, near: Float, far: Float) -> simd_float4x4 {
        simd_float4x4(columns: (
            SIMD4(2 / (right - left), 0, 0, 0),
            SIMD4(0, 2 / (top - bottom), 0, 0),
            SIMD4(0, 0, -1 / (far - near), 0),
            SIMD4(-(right + left) / (right - left), -(top + bottom) / (top - bottom), -near / (far - near), 1)
        ))
    }

    public static func lookAt(eye: SIMD3<Float>, target: SIMD3<Float>, up: SIMD3<Float> = [0, 1, 0]) -> simd_float4x4 {
        let f = simd_normalize(target - eye)
        var upVector = up
        if abs(simd_dot(f, simd_normalize(up))) > 0.999 { upVector = [0, 0, 1] }
        let s = simd_normalize(simd_cross(f, upVector))
        let u = simd_cross(s, f)
        return simd_float4x4(columns: (
            SIMD4(s.x, u.x, -f.x, 0),
            SIMD4(s.y, u.y, -f.y, 0),
            SIMD4(s.z, u.z, -f.z, 0),
            SIMD4(-simd_dot(s, eye), -simd_dot(u, eye), simd_dot(f, eye), 1)
        ))
    }

    /// Rotation by `yaw` radians about +y (studio frame -> world frame).
    public static func yawRotate(_ v: SIMD3<Float>, _ yaw: Float) -> SIMD3<Float> {
        let c = cos(yaw), s = sin(yaw)
        return SIMD3(v.x * c + v.z * s, v.y, -v.x * s + v.z * c)
    }

    /// The 3×3 inverse transpose of the upper-left of `m`, as three columns (for normals).
    public static func normalMatrix(_ m: simd_float4x4) -> simd_float3x3 {
        let upper = simd_float3x3(columns: (m.columns.0.xyz, m.columns.1.xyz, m.columns.2.xyz))
        let det = upper.determinant
        guard abs(det) > 1e-12 else { return upper }
        return upper.inverse.transpose
    }

    /// Smooth start and stop.
    public static func ease(_ t: Double) -> Double {
        let x = min(1, max(0, t))
        return x * x * (3 - 2 * x)
    }

    /// Ease out with a little overshoot, for parts growing in.
    public static func easeOutBack(_ t: Double) -> Double {
        let x = min(1, max(0, t))
        let c1 = 1.4, c3 = c1 + 1
        return 1 + c3 * pow(x - 1, 3) + c1 * pow(x - 1, 2)
    }
}

extension SIMD4 where Scalar == Float {
    var xyz: SIMD3<Float> { SIMD3(x, y, z) }
}

extension JSONValue {
    /// `[x, y, z]` as a float vector.
    var vector3: SIMD3<Float>? {
        guard let array = arrayValue, array.count >= 3,
              let x = array[0].doubleValue, let y = array[1].doubleValue, let z = array[2].doubleValue else { return nil }
        return SIMD3(Float(x), Float(y), Float(z))
    }

    var vector4: SIMD4<Float>? {
        guard let array = arrayValue, array.count >= 4 else { return nil }
        let values = array.prefix(4).compactMap(\.doubleValue)
        guard values.count == 4 else { return nil }
        return SIMD4(Float(values[0]), Float(values[1]), Float(values[2]), Float(values[3]))
    }

    var float: Float? { doubleValue.map(Float.init) }
}

/// `#RRGGBB` -> sRGB 0...1, and the linear-light version used for shading.
public enum FigureColor {
    public static func srgb(hex: String) -> SIMD3<Float>? {
        var text = hex.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6, let value = UInt32(text, radix: 16) else { return nil }
        return srgb(rgb24: value)
    }

    public static func srgb(rgb24 value: UInt32) -> SIMD3<Float> {
        SIMD3(Float((value >> 16) & 0xFF), Float((value >> 8) & 0xFF), Float(value & 0xFF)) / 255
    }

    public static func linear(_ srgb: SIMD3<Float>) -> SIMD3<Float> {
        func channel(_ c: Float) -> Float { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return SIMD3(channel(srgb.x), channel(srgb.y), channel(srgb.z))
    }

    public static func linear(hex: String) -> SIMD3<Float>? { srgb(hex: hex).map(linear) }
}
