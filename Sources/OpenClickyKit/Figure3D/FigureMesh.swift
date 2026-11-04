import Foundation
import simd

/// A built part mesh, ready for the GPU: interleaved vertices (position, normal, uv as 8 floats = 32 bytes), 32-bit
/// triangle indices, and up to 512 framing samples used to fit the camera. Immutable, so it is shared freely between
/// the kernel's cache, scenes and renderers; renderers key their GPU buffers by the instance.
public final class FigureMesh: Sendable {
    public static let floatsPerVertex = 8
    public static let vertexStride = floatsPerVertex * MemoryLayout<Float>.stride

    public let vertices: [Float]
    public let indices: [UInt32]
    public let samples: [SIMD3<Float>]
    public let boundsMin: SIMD3<Float>
    public let boundsMax: SIMD3<Float>

    public init(vertices: [Float], indices: [UInt32], samples: [SIMD3<Float>], boundsMin: SIMD3<Float>, boundsMax: SIMD3<Float>) {
        self.vertices = vertices
        self.indices = indices
        self.samples = samples
        self.boundsMin = boundsMin
        self.boundsMax = boundsMax
    }

    /// Interleave separate arrays (as the kernel returns them).
    public convenience init(positions: [Float], normals: [Float], uvs: [Float], indices: [UInt32], samples: [Float], bounds: [Float]) {
        let count = positions.count / 3
        var vertices = [Float](repeating: 0, count: count * Self.floatsPerVertex)
        let hasUV = uvs.count >= count * 2
        let hasNormals = normals.count >= count * 3
        for i in 0..<count {
            let o = i * Self.floatsPerVertex
            vertices[o] = positions[i * 3]
            vertices[o + 1] = positions[i * 3 + 1]
            vertices[o + 2] = positions[i * 3 + 2]
            if hasNormals {
                vertices[o + 3] = normals[i * 3]
                vertices[o + 4] = normals[i * 3 + 1]
                vertices[o + 5] = normals[i * 3 + 2]
            }
            if hasUV {
                vertices[o + 6] = uvs[i * 2]
                vertices[o + 7] = uvs[i * 2 + 1]
            }
        }
        var points: [SIMD3<Float>] = []
        points.reserveCapacity(samples.count / 3)
        for i in stride(from: 0, to: samples.count - 2, by: 3) { points.append(SIMD3(samples[i], samples[i + 1], samples[i + 2])) }
        let lo = bounds.count >= 6 ? SIMD3(bounds[0], bounds[1], bounds[2]) : .zero
        let hi = bounds.count >= 6 ? SIMD3(bounds[3], bounds[4], bounds[5]) : .zero
        self.init(vertices: vertices, indices: indices, samples: points, boundsMin: lo, boundsMax: hi)
    }

    public var vertexCount: Int { vertices.count / Self.floatsPerVertex }
    public var triangleCount: Int { indices.count / 3 }
    /// Approximate memory held, for the kernel's cache budget.
    public var byteSize: Int { vertices.count * 4 + indices.count * 4 + samples.count * 16 }

    public func position(_ index: Int) -> SIMD3<Float> {
        let o = index * Self.floatsPerVertex
        return SIMD3(vertices[o], vertices[o + 1], vertices[o + 2])
    }

    public func normal(_ index: Int) -> SIMD3<Float> {
        let o = index * Self.floatsPerVertex
        return SIMD3(vertices[o + 3], vertices[o + 4], vertices[o + 5])
    }

    /// Fraction of non-degenerate triangles whose winding (counter-clockwise = front) agrees with their vertex
    /// normals. 1 means every face points the way it is shaded; mirrored meshes must keep this at 1.
    public func windingAgreement() -> Double {
        var agree = 0, total = 0
        for t in stride(from: 0, to: indices.count, by: 3) {
            let a = Int(indices[t]), b = Int(indices[t + 1]), c = Int(indices[t + 2])
            let face = simd_cross(position(b) - position(a), position(c) - position(a))
            guard simd_length(face) > 1e-9 else { continue }
            total += 1
            if simd_dot(face, normal(a) + normal(b) + normal(c)) > 0 { agree += 1 }
        }
        return total == 0 ? 1 : Double(agree) / Double(total)
    }

    /// Fraction of non-degenerate triangles that face away from the mesh's centre (outward, for convex shapes).
    public func outwardFraction() -> Double {
        let center = (boundsMin + boundsMax) / 2
        var outward = 0, total = 0
        for t in stride(from: 0, to: indices.count, by: 3) {
            let a = position(Int(indices[t])), b = position(Int(indices[t + 1])), c = position(Int(indices[t + 2]))
            let face = simd_cross(b - a, c - a)
            guard simd_length(face) > 1e-9 else { continue }
            total += 1
            if simd_dot(face, (a + b + c) / 3 - center) > 0 { outward += 1 }
        }
        return total == 0 ? 1 : Double(outward) / Double(total)
    }
}
