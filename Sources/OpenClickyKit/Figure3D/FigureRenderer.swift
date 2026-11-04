import CoreGraphics
import Foundation
import Metal
import simd

public enum FigureRendererError: Error, CustomStringConvertible {
    case noDevice
    case shaders(String)
    case pipeline(String)
    case resources(String)

    public var description: String {
        switch self {
        case .noDevice: "3D renderer: no Metal device"
        case .shaders(let message): "3D shaders failed to compile: \(message)"
        case .pipeline(let message): "3D renderer pipeline failed: \(message)"
        case .resources(let message): "3D renderer resources failed: \(message)"
        }
    }
}

/// Lighting and grading constants of the two looks. Studio defaults are tuned for figures on a light paper card
/// or floating over a screen.
public struct FigureLookSettings: Sendable {
    public var keyDirection: SIMD3<Float> = simd_normalize([-0.5, 0.82, 0.48])
    public var keyIntensity: Float = 3.0
    public var rimDirection: SIMD3<Float> = simd_normalize([0.72, 0.32, -0.62])
    public var rimIntensity: Float = 1.1
    public var environmentStrength: Float = 1.0
    public var exposure: Float = 1.05
    public var saturation: Float = 1.08
    public var groundShadowOpacity: Float = 0.42
    public var shadowSoftness: Float = 1.0
    public var occlusionRadius: Float = 0.11
    public var occlusionStrength: Float = 1.5
    /// Room brightness and the four softboxes: key, right strip, overhead, back strip.
    public var room: Float = 0.9
    public var softboxes: SIMD4<Float> = [5.5, 3.6, 2.2, 2.6]
    /// The broad dim panel behind the camera.
    public var frontFill: Float = 0.9
    /// The white bounce card on the floor in front of the object.
    public var bounceCard: Float = 1.1
    /// Ink pen half width in points (illustrated look).
    public var penHalfWidth: Float = 1.15
    public var seamStrength: Float = 0.85

    public init() {}
}

/// Draws figures with Metal in the studio or illustrated look, into a CAMetalLayer drawable or an offscreen
/// texture, and reads part ids back for picking. Shaders are compiled at run time from Resources/metal.
///
/// The illustrated look (and picking) is the core: without it the renderer can't be made. The studio look is compiled
/// separately, and when its shaders or pipelines fail, studio figures are drawn in the illustrated look instead
/// (`studioError`). The studio shadow map is kept while the lights and the geometry stay put, and ambient occlusion
/// runs at half resolution.
public final class FigureRenderer {
    public let device: MTLDevice
    public var settings = FigureLookSettings()
    let queue: MTLCommandQueue
    public static let colorFormat = MTLPixelFormat.bgra8Unorm
    static let sampleCount = 4

    private let library: MTLLibrary
    private let vertexDescriptor: MTLVertexDescriptor
    /// The studio look's pipelines; nil when they failed (studio frames are then drawn illustrated).
    private let studio: StudioPipelines?
    /// Why the studio look isn't available, when it isn't.
    public let studioError: FigureRendererError?
    // Illustrated and ids.
    private let toonSolid: MTLRenderPipelineState
    private let toonCut: MTLRenderPipelineState
    private let toonGlass: MTLRenderPipelineState
    private let idPipeline: MTLRenderPipelineState
    private let idCutPipeline: MTLRenderPipelineState
    private let outlinePipeline: MTLRenderPipelineState

    private let depthWrite: MTLDepthStencilState
    private let depthRead: MTLDepthStencilState
    private let depthAlways: MTLDepthStencilState
    private let compareSampler: MTLSamplerState
    private let pointSampler: MTLSamplerState
    private let linearSampler: MTLSamplerState

    private var environmentBase: MTLTexture?
    private var environmentSpecular: MTLTexture?
    private var environmentIrradiance: MTLTexture?
    private var environmentBaked = false
    private let specularLevels = 6
    private var shadowMap: MTLTexture?
    /// What the shadow map holds (the light and every shadow caster's mesh, placement and cut); nil when stale.
    private var shadowKey: Int?
    /// Shadow passes drawn so far (tests: a still figure draws one).
    private(set) var shadowPasses = 0
    /// Render targets by pixel size, most recently used last (a stage may show figures of several sizes).
    private var targetCache: [Targets] = []
    private var meshBuffers: [ObjectIdentifier: MeshBuffers] = [:]

    private struct MeshBuffers {
        weak var owner: FigureMesh?
        let vertices: MTLBuffer
        let indices: MTLBuffer
        let count: Int
    }

    private struct StudioPipelines {
        let solid: MTLRenderPipelineState
        let cut: MTLRenderPipelineState
        let ground: MTLRenderPipelineState
        let shadow: MTLRenderPipelineState
        let normalDepth: MTLRenderPipelineState
        let occlusion: MTLRenderPipelineState
        let occlusionBlur: MTLRenderPipelineState
        let envBake: MTLComputePipelineState
        let envPrefilter: MTLComputePipelineState
        let envIrradiance: MTLComputePipelineState
    }

    private struct Targets {
        let width: Int
        let height: Int
        let msaaColor: MTLTexture
        let msaaDepth: MTLTexture
        let ids: MTLTexture
        let idDepth: MTLTexture
        /// Normals, depth and occlusion are half the size of the frame (the occlusion is soft anyway).
        let normalDepth: MTLTexture
        let normalDepthDepth: MTLTexture
        let occlusionRaw: MTLTexture
        let occlusion: MTLTexture
    }

    /// The four shader files, concatenated in dependency order.
    public static func shaderSource() throws -> String {
        try source(["figure-common", "figure-environment", "figure-studio", "figure-illustrated"])
    }

    /// What the illustrated look and picking need: the shared definitions and the ink shaders.
    public static func coreShaderSource() throws -> String {
        try source(["figure-common", "figure-illustrated"])
    }

    /// The studio look on its own (with the shared definitions), compiled separately so a failure there leaves the
    /// illustrated look working.
    public static func studioShaderSource() throws -> String {
        try source(["figure-common", "figure-environment", "figure-studio"])
    }

    private static func source(_ names: [String]) throws -> String {
        try names.map { name in
            do { return try KitResources.text(name, "metal", in: "metal") } catch {
                throw FigureRendererError.shaders("\(name).metal is missing")
            }
        }.joined(separator: "\n")
    }

    /// Compile the figure shaders in the background (call it at launch). The first compile of new shader source
    /// takes about a second; afterwards the system's shader cache answers in about a millisecond, so the first figure
    /// doesn't stall the main thread.
    ///
    /// `completion` gets the core (illustrated) compile's error: without it there are no figures. `studio` gets the
    /// studio compile's error, which only costs the studio look.
    public static func warmUpShaders(device: MTLDevice? = nil, completion: (@Sendable (Error?) -> Void)? = nil,
                                     studio: (@Sendable (Error?) -> Void)? = nil) {
        guard let device = device ?? MTLCreateSystemDefaultDevice() else {
            completion?(FigureRendererError.noDevice)
            studio?(FigureRendererError.noDevice)
            return
        }
        do {
            let core = try coreShaderSource()
            let studioSource = try studioShaderSource()
            device.makeLibrary(source: core, options: nil) { _, error in
                completion?(error.map { FigureRendererError.shaders("\($0)") })
                guard error == nil else {
                    studio?(error)
                    return
                }
                device.makeLibrary(source: studioSource, options: nil) { _, error in studio?(error.map { FigureRendererError.shaders("\($0)") }) }
            }
        } catch {
            completion?(error)
            studio?(error)
        }
    }

    public convenience init(device: MTLDevice? = nil) throws {
        try self.init(device: device, studioSource: nil)
    }

    /// `studioSource` replaces the studio shaders (tests use a broken one to check the illustrated fallback).
    init(device: MTLDevice?, studioSource: String?) throws {
        guard let device = device ?? MTLCreateSystemDefaultDevice() else { throw FigureRendererError.noDevice }
        self.device = device
        guard let queue = device.makeCommandQueue() else { throw FigureRendererError.resources("command queue") }
        self.queue = queue
        func compile(_ source: () throws -> String) throws -> MTLLibrary {
            do {
                return try device.makeLibrary(source: try source(), options: nil)
            } catch let error as FigureRendererError {
                throw error
            } catch {
                throw FigureRendererError.shaders("\(error)")
            }
        }
        let lib = try compile(Self.coreShaderSource)
        library = lib

        let descriptor = MTLVertexDescriptor()
        descriptor.attributes[0].format = .float3
        descriptor.attributes[0].offset = 0
        descriptor.attributes[0].bufferIndex = 0
        descriptor.attributes[1].format = .float3
        descriptor.attributes[1].offset = 12
        descriptor.attributes[1].bufferIndex = 0
        descriptor.attributes[2].format = .float2
        descriptor.attributes[2].offset = 24
        descriptor.attributes[2].bufferIndex = 0
        descriptor.layouts[0].stride = FigureMesh.vertexStride
        vertexDescriptor = descriptor

        func function(_ name: String, in library: MTLLibrary) throws -> MTLFunction {
            guard let function = library.makeFunction(name: name) else { throw FigureRendererError.pipeline("missing \(name)") }
            return function
        }
        func render(_ vertex: String, _ fragment: String?, color: MTLPixelFormat?, depth: MTLPixelFormat?,
                    samples: Int = 1, blend: Bool = false, mesh: Bool = true, library: MTLLibrary? = nil) throws -> MTLRenderPipelineState {
            let library = library ?? lib
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = try function(vertex, in: library)
            d.fragmentFunction = try fragment.map { try function($0, in: library) }
            if mesh { d.vertexDescriptor = descriptor }
            if let color {
                d.colorAttachments[0].pixelFormat = color
                if blend {
                    d.colorAttachments[0].isBlendingEnabled = true
                    d.colorAttachments[0].sourceRGBBlendFactor = .one
                    d.colorAttachments[0].sourceAlphaBlendFactor = .one
                    d.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
                    d.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
                }
            }
            if let depth { d.depthAttachmentPixelFormat = depth }
            d.rasterSampleCount = samples
            do { return try device.makeRenderPipelineState(descriptor: d) } catch {
                throw FigureRendererError.pipeline("\(vertex)/\(fragment ?? "-"): \(error)")
            }
        }
        func compute(_ name: String, in library: MTLLibrary) throws -> MTLComputePipelineState {
            do { return try device.makeComputePipelineState(function: try function(name, in: library)) } catch {
                throw FigureRendererError.pipeline("\(name): \(error)")
            }
        }
        let color = Self.colorFormat
        let n = Self.sampleCount
        // The studio look is optional: if its shaders or pipelines fail, studio figures are drawn illustrated.
        do {
            let studioLibrary = try compile { try studioSource ?? Self.studioShaderSource() }
            studio = StudioPipelines(
                solid: try render("fig_vertex", "fig_studio_fragment", color: color, depth: .depth32Float, samples: n, blend: true, library: studioLibrary),
                cut: try render("fig_vertex", "fig_studio_cut_fragment", color: color, depth: .depth32Float, samples: n, blend: true, library: studioLibrary),
                ground: try render("fig_ground_vertex", "fig_ground_fragment", color: color, depth: .depth32Float, samples: n, blend: true, mesh: false,
                                   library: studioLibrary),
                shadow: try render("fig_shadow_vertex", "fig_shadow_fragment", color: nil, depth: .depth32Float, library: studioLibrary),
                normalDepth: try render("fig_vertex", "fig_normal_depth_fragment", color: .rgba16Float, depth: .depth32Float, library: studioLibrary),
                occlusion: try render("fig_fullscreen_vertex", "fig_ao_fragment", color: .r16Float, depth: nil, mesh: false, library: studioLibrary),
                occlusionBlur: try render("fig_fullscreen_vertex", "fig_ao_blur_fragment", color: .r16Float, depth: nil, mesh: false, library: studioLibrary),
                envBake: try compute("fig_env_bake", in: studioLibrary),
                envPrefilter: try compute("fig_env_prefilter", in: studioLibrary),
                envIrradiance: try compute("fig_env_irradiance", in: studioLibrary))
            studioError = nil
        } catch {
            studio = nil
            studioError = (error as? FigureRendererError) ?? .pipeline("\(error)")
        }
        toonSolid = try render("fig_vertex", "fig_toon_fragment", color: color, depth: .depth32Float, samples: n, blend: true)
        toonCut = try render("fig_vertex", "fig_toon_cut_fragment", color: color, depth: .depth32Float, samples: n, blend: true)
        toonGlass = toonSolid
        idPipeline = try render("fig_vertex", "fig_id_fragment", color: .r32Uint, depth: .depth32Float)
        idCutPipeline = try render("fig_vertex", "fig_id_cut_fragment", color: .r32Uint, depth: .depth32Float)
        outlinePipeline = try render("fig_fullscreen_vertex", "fig_outline_fragment", color: color, depth: nil, blend: true, mesh: false)

        func depthState(_ compare: MTLCompareFunction, write: Bool) throws -> MTLDepthStencilState {
            let d = MTLDepthStencilDescriptor()
            d.depthCompareFunction = compare
            d.isDepthWriteEnabled = write
            guard let state = device.makeDepthStencilState(descriptor: d) else { throw FigureRendererError.resources("depth state") }
            return state
        }
        depthWrite = try depthState(.less, write: true)
        depthRead = try depthState(.lessEqual, write: false)
        depthAlways = try depthState(.always, write: false)

        func sampler(_ configure: (MTLSamplerDescriptor) -> Void) throws -> MTLSamplerState {
            let d = MTLSamplerDescriptor()
            d.sAddressMode = .clampToEdge
            d.tAddressMode = .clampToEdge
            d.rAddressMode = .clampToEdge
            configure(d)
            guard let state = device.makeSamplerState(descriptor: d) else { throw FigureRendererError.resources("sampler") }
            return state
        }
        compareSampler = try sampler { $0.minFilter = .linear; $0.magFilter = .linear; $0.compareFunction = .lessEqual }
        pointSampler = try sampler { $0.minFilter = .nearest; $0.magFilter = .nearest }
        linearSampler = try sampler { $0.minFilter = .linear; $0.magFilter = .linear; $0.mipFilter = .linear }
    }

    // MARK: - Public entry points

    /// True when the studio look compiled; otherwise studio frames are drawn in the illustrated look.
    public var isStudioAvailable: Bool { studio != nil }

    /// The look a frame asking for `look` is actually drawn in.
    public func effectiveLook(_ look: FigureLook) -> FigureLook {
        look == .studio && studio == nil ? .illustrated : look
    }

    /// The longest side, in pixels, of any texture a figure is drawn into (Metal allows 16384). A figure that would
    /// be bigger at the requested scale is drawn at a lower one.
    public static let maxPixelSide: CGFloat = 8192

    /// Pixels per point used for a figure of `viewport` points: `scale`, lowered so neither side exceeds `maxPixelSide`.
    public static func effectiveScale(for viewport: CGSize, scale: CGFloat) -> CGFloat {
        let requested = scale.isFinite && scale > 0 ? scale : 1
        let longest = max(1, viewport.width.isFinite ? viewport.width : 1, viewport.height.isFinite ? viewport.height : 1)
        return min(requested, maxPixelSide / longest)
    }

    /// Pixel size of a viewport at `scale` pixels per point (lowered by `effectiveScale` for very large figures).
    public static func pixelSize(viewport: CGSize, scale: CGFloat) -> (width: Int, height: Int) {
        let s = effectiveScale(for: viewport, scale: scale)
        func side(_ points: CGFloat) -> Int {
            guard points.isFinite else { return 1 }
            return min(Int(maxPixelSide), max(1, Int((points * s).rounded())))
        }
        return (side(viewport.width), side(viewport.height))
    }

    /// Pixel size of a frame at `scale` pixels per point.
    public static func pixelSize(_ frame: FigureFrame, scale: CGFloat) -> (width: Int, height: Int) {
        pixelSize(viewport: frame.viewport, scale: scale)
    }

    /// Encode a full frame into `target` (a drawable texture or an offscreen texture of the same pixel size). Encodes
    /// nothing if the target is larger than `maxPixelSide` or its work textures can't be made.
    public func encode(_ frame: FigureFrame, scale: CGFloat, into target: MTLTexture, commandBuffer: MTLCommandBuffer,
                       clear: MTLClearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)) {
        guard let targets = targets(width: target.width, height: target.height) else { return }
        let look = effectiveLook(frame.look)
        if look == .studio, let studio, !environmentBaked { bakeEnvironment(commandBuffer, studio) }
        let scale = Self.effectiveScale(for: frame.viewport, scale: scale)
        var uniforms = frameUniforms(frame, width: target.width, height: target.height, scale: scale)
        let items = frame.items
        switch look {
        case .studio:
            guard let studio else { return }
            // The shadow map only changes when the light or a shadow caster does: a figure whose labels are still being
            // written, or whose parts stand still, reuses it.
            let key = Self.shadowKey(items, lightViewProj: uniforms.lightViewProj)
            if key != shadowKey {
                shadowKey = encodeShadow(items, uniforms: &uniforms, commandBuffer: commandBuffer, studio) ? key : nil
            }
            encodeOcclusion(items, uniforms: &uniforms, targets: targets, commandBuffer: commandBuffer, studio)
            encodeMain(items, uniforms: &uniforms, targets: targets, target: target, clear: clear, commandBuffer: commandBuffer, studio: studio)
        case .illustrated:
            encodeIDs(items, uniforms: &uniforms, into: targets.ids, depth: targets.idDepth, commandBuffer: commandBuffer)
            encodeMain(items, uniforms: &uniforms, targets: targets, target: target, clear: clear, commandBuffer: commandBuffer, studio: nil)
            encodeOutline(uniforms: &uniforms, ids: targets.ids, target: target, commandBuffer: commandBuffer)
        }
    }

    /// Render a frame offscreen. `background` (sRGB, 0...1, alpha) is composited under the figure; nil keeps it
    /// transparent.
    public func renderImage(_ frame: FigureFrame, scale: CGFloat, background: SIMD4<Float>? = nil) throws -> CGImage {
        let (width, height) = Self.pixelSize(frame, scale: scale)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: Self.colorFormat, width: width, height: height, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = device.hasUnifiedMemory ? .shared : .managed
        guard let texture = device.makeTexture(descriptor: descriptor), let commandBuffer = queue.makeCommandBuffer() else {
            throw FigureRendererError.resources("offscreen target")
        }
        let clear = background.map {
            MTLClearColor(red: Double($0.x * $0.w), green: Double($0.y * $0.w), blue: Double($0.z * $0.w), alpha: Double($0.w))
        } ?? MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        encode(frame, scale: scale, into: texture, commandBuffer: commandBuffer, clear: clear)
        synchronize(texture, commandBuffer)
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        if let error = commandBuffer.error { throw FigureRendererError.resources("GPU: \(error)") }
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        texture.getBytes(&bytes, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        else { throw FigureRendererError.resources("image") }
        return image
    }

    /// The picking id under `point` (points, top-left origin of the figure rectangle); 0 means no part. The high bit
    /// (cut face) is cleared. Only the one pixel is read back, so hover tests stay cheap.
    public func pick(_ frame: FigureFrame, scale: CGFloat, at point: CGPoint) -> UInt32 {
        let (width, height) = Self.pixelSize(frame, scale: scale)
        let s = Self.effectiveScale(for: frame.viewport, scale: scale)
        guard point.x.isFinite, point.y.isFinite else { return 0 }
        let x = Int((point.x * s).rounded(.down)), y = Int((point.y * s).rounded(.down))
        guard x >= 0, y >= 0, x < width, y < height, let ids = renderIDs(frame, scale: scale) else { return 0 }
        var id: UInt32 = 0
        ids.getBytes(&id, bytesPerRow: 4, from: MTLRegionMake2D(x, y, 1, 1), mipmapLevel: 0)
        return id & 0x7FFF_FFFF
    }

    /// The whole id buffer (with the cut-face bit), for tests and hover maps.
    public func idGrid(_ frame: FigureFrame, scale: CGFloat) -> (ids: [UInt32], width: Int, height: Int) {
        let (width, height) = Self.pixelSize(frame, scale: scale)
        guard let texture = renderIDs(frame, scale: scale) else { return ([], 0, 0) }
        var ids = [UInt32](repeating: 0, count: width * height)
        texture.getBytes(&ids, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        return (ids, width, height)
    }

    /// Draw the part-id buffer for a frame and wait for it.
    private func renderIDs(_ frame: FigureFrame, scale: CGFloat) -> MTLTexture? {
        let (width, height) = Self.pixelSize(frame, scale: scale)
        guard let targets = targets(width: width, height: height), let commandBuffer = queue.makeCommandBuffer() else { return nil }
        var uniforms = frameUniforms(frame, width: width, height: height, scale: Self.effectiveScale(for: frame.viewport, scale: scale))
        encodeIDs(frame.items, uniforms: &uniforms, into: targets.ids, depth: targets.idDepth, commandBuffer: commandBuffer)
        synchronize(targets.ids, commandBuffer)
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        return commandBuffer.error == nil ? targets.ids : nil
    }

    // MARK: - Uniforms

    struct FrameUniforms {
        var viewProj: simd_float4x4
        var view: simd_float4x4
        var lightViewProj: simd_float4x4
        var eye: SIMD4<Float>
        var keyDir: SIMD4<Float>
        var keyColor: SIMD4<Float>
        var rimDir: SIMD4<Float>
        var rimColor: SIMD4<Float>
        var env: SIMD4<Float>
        var shadow: SIMD4<Float>
        var ground: SIMD4<Float>
        var groundTint: SIMD4<Float>
        var ao: SIMD4<Float>
        var viewport: SIMD4<Float>
        var ink: SIMD4<Float>
        var proj: SIMD4<Float>
        var hatch: SIMD4<Float>
        var look: SIMD4<Float>
    }

    struct ObjectUniforms {
        var model: simd_float4x4
        var normal0: SIMD4<Float>
        var normal1: SIMD4<Float>
        var normal2: SIMD4<Float>
        var baseColor: SIMD4<Float>
        var emissive: SIMD4<Float>
        var surface: SIMD4<Float>
        var extra: SIMD4<Float>
        var cut: SIMD4<Float>
        var misc: SIMD4<Float>
        var ids: SIMD4<UInt32>
    }

    private func frameUniforms(_ frame: FigureFrame, width: Int, height: Int, scale: CGFloat) -> FrameUniforms {
        let s = settings
        let r = max(frame.radius, 0.05)
        // Lights live in the studio frame, which turns with the camera.
        let key = simd_normalize(FigureMath.yawRotate(s.keyDirection, frame.yaw))
        let rim = simd_normalize(FigureMath.yawRotate(s.rimDirection, frame.yaw))
        let lightDistance = r * 4
        let lightEye = frame.center + key * lightDistance
        let lightView = FigureMath.lookAt(eye: lightEye, target: frame.center, up: abs(key.y) > 0.98 ? [0, 0, 1] : [0, 1, 0])
        let extent = r * 1.3
        let lightProjection = FigureMath.orthographic(left: -extent, right: extent, bottom: -extent, top: extent,
                                                      near: r * 0.5, far: lightDistance + r * 3)
        let depthRange = lightDistance + r * 3 - r * 0.5
        let shadowSize: Float = 2048
        let texelWorld = 2 * extent / shadowSize
        let penumbra = depthRange * (shadowSize / (2 * extent)) * 0.05 * s.shadowSoftness
        return FrameUniforms(
            viewProj: frame.viewProjection, view: frame.view, lightViewProj: lightProjection * lightView,
            eye: SIMD4(frame.eye, 1),
            keyDir: SIMD4(key, 0), keyColor: SIMD4(SIMD3<Float>(1, 0.965, 0.92) * s.keyIntensity, 0),
            rimDir: SIMD4(rim, 0), rimColor: SIMD4(SIMD3<Float>(0.86, 0.92, 1) * s.rimIntensity, 0),
            env: SIMD4(cos(frame.yaw), sin(frame.yaw), s.environmentStrength, s.exposure),
            shadow: SIMD4(1 / shadowSize, 0.0012, texelWorld * 1.5, penumbra),
            ground: SIMD4(frame.groundY - r * 0.004, frame.center.x, frame.center.z, r * 2.2),
            groundTint: SIMD4(SIMD3<Float>(0.03, 0.035, 0.045), s.groundShadowOpacity),
            ao: SIMD4(r * s.occlusionRadius, s.occlusionStrength, 1, 0),
            viewport: SIMD4(Float(width), Float(height), 1 / Float(width), 1 / Float(height)),
            ink: SIMD4(frame.ink, s.penHalfWidth * Float(scale)),
            proj: SIMD4(frame.projection.columns.0.x, frame.projection.columns.1.y, frame.near, frame.far),
            hatch: SIMD4(r * 0.07, 0.14, Float(specularLevels - 1), 0),
            look: SIMD4(s.seamStrength, s.saturation, 0, 0))
    }

    private func objectUniforms(_ item: FigureDrawItem) -> ObjectUniforms {
        let n = FigureMath.normalMatrix(item.model)
        let m = item.material
        return ObjectUniforms(
            model: item.model,
            normal0: SIMD4(n.columns.0, 0), normal1: SIMD4(n.columns.1, 0), normal2: SIMD4(n.columns.2, 0),
            baseColor: SIMD4(m.color, m.opacity), emissive: SIMD4(m.emissive, m.glow),
            surface: SIMD4(m.roughness, m.metalness, m.clearcoat, m.clearcoatRoughness),
            extra: SIMD4(m.sheen, m.isGlass ? 1 : 0, m.flat ? 1 : 0, m.doubleSided ? 1 : 0),
            cut: item.cut ?? .zero, misc: SIMD4(item.highlight, 0, 0, 0),
            ids: SIMD4(item.pickID, item.cut == nil ? 0 : 1, 0, 0))
    }

    // MARK: - Passes

    private func draw(_ item: FigureDrawItem, _ encoder: MTLRenderCommandEncoder, uniforms: inout FrameUniforms) {
        guard let buffers = buffers(for: item.mesh) else { return }
        var object = objectUniforms(item)
        encoder.setVertexBuffer(buffers.vertices, offset: 0, index: 0)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<FrameUniforms>.stride, index: 1)
        encoder.setVertexBytes(&object, length: MemoryLayout<ObjectUniforms>.stride, index: 2)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<FrameUniforms>.stride, index: 1)
        encoder.setFragmentBytes(&object, length: MemoryLayout<ObjectUniforms>.stride, index: 2)
        encoder.drawIndexedPrimitives(type: .triangle, indexCount: buffers.count, indexType: .uint32, indexBuffer: buffers.indices, indexBufferOffset: 0)
    }

    private func cullMode(_ item: FigureDrawItem) -> MTLCullMode {
        item.cut != nil || item.material.doubleSided || item.material.isGlass ? .none : .back
    }

    /// Identifies what a shadow map shows: the light's view and each opaque part's mesh, placement and cut.
    static func shadowKey(_ items: [FigureDrawItem], lightViewProj: simd_float4x4) -> Int {
        var hasher = Hasher()
        func add(_ m: simd_float4x4) {
            for column in [m.columns.0, m.columns.1, m.columns.2, m.columns.3] {
                hasher.combine(column.x); hasher.combine(column.y); hasher.combine(column.z); hasher.combine(column.w)
            }
        }
        add(lightViewProj)
        for item in items where !item.material.isGlass {
            hasher.combine(ObjectIdentifier(item.mesh))
            add(item.model)
            if let cut = item.cut { hasher.combine(cut.x); hasher.combine(cut.y); hasher.combine(cut.z); hasher.combine(cut.w) }
        }
        return hasher.finalize()
    }

    /// Draws the shadow map; false when nothing was encoded.
    private func encodeShadow(_ items: [FigureDrawItem], uniforms: inout FrameUniforms, commandBuffer: MTLCommandBuffer,
                              _ studio: StudioPipelines) -> Bool {
        guard let map = shadowTexture() else { return false }
        let pass = MTLRenderPassDescriptor()
        pass.depthAttachment.texture = map
        pass.depthAttachment.loadAction = .clear
        pass.depthAttachment.storeAction = .store
        pass.depthAttachment.clearDepth = 1
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return false }
        encoder.label = "figure shadow"
        encoder.setRenderPipelineState(studio.shadow)
        encoder.setDepthStencilState(depthWrite)
        encoder.setFrontFacing(.counterClockwise)
        encoder.setDepthBias(1, slopeScale: 1.5, clamp: 0.01)
        for item in items where !item.material.isGlass {
            encoder.setCullMode(.none)
            draw(item, encoder, uniforms: &uniforms)
        }
        encoder.endEncoding()
        shadowPasses += 1
        return true
    }

    private func encodeOcclusion(_ items: [FigureDrawItem], uniforms: inout FrameUniforms, targets: Targets, commandBuffer: MTLCommandBuffer,
                                 _ studio: StudioPipelines) {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = targets.normalDepth
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        pass.depthAttachment.texture = targets.normalDepthDepth
        pass.depthAttachment.loadAction = .clear
        pass.depthAttachment.storeAction = .dontCare
        pass.depthAttachment.clearDepth = 1
        if let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) {
            encoder.label = "figure normals + depth"
            encoder.setRenderPipelineState(studio.normalDepth)
            encoder.setDepthStencilState(depthWrite)
            encoder.setFrontFacing(.counterClockwise)
            for item in items where !item.material.isTransparent {
                encoder.setCullMode(cullMode(item))
                draw(item, encoder, uniforms: &uniforms)
            }
            encoder.endEncoding()
        }
        fullscreen(studio.occlusion, into: targets.occlusionRaw, textures: [targets.normalDepth], uniforms: &uniforms, commandBuffer: commandBuffer)
        fullscreen(studio.occlusionBlur, into: targets.occlusion, textures: [targets.occlusionRaw, targets.normalDepth], uniforms: &uniforms, commandBuffer: commandBuffer)
    }

    private func fullscreen(_ pipeline: MTLRenderPipelineState, into texture: MTLTexture, textures: [MTLTexture],
                            uniforms: inout FrameUniforms, commandBuffer: MTLCommandBuffer) {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.setRenderPipelineState(pipeline)
        for (index, texture) in textures.enumerated() { encoder.setFragmentTexture(texture, index: index) }
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<FrameUniforms>.stride, index: 1)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
    }

    private func encodeMain(_ items: [FigureDrawItem], uniforms: inout FrameUniforms, targets: Targets, target: MTLTexture,
                            clear: MTLClearColor, commandBuffer: MTLCommandBuffer, studio: StudioPipelines?) {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = targets.msaaColor
        pass.colorAttachments[0].resolveTexture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .multisampleResolve
        pass.colorAttachments[0].clearColor = clear
        pass.depthAttachment.texture = targets.msaaDepth
        pass.depthAttachment.loadAction = .clear
        pass.depthAttachment.storeAction = .dontCare
        pass.depthAttachment.clearDepth = 1
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.label = studio != nil ? "figure studio" : "figure illustrated"
        encoder.setFrontFacing(.counterClockwise)
        if let studio {
            encoder.setFragmentTexture(shadowTexture(), index: 0)
            encoder.setFragmentTexture(environmentSpecular, index: 1)
            encoder.setFragmentTexture(environmentIrradiance, index: 2)
            encoder.setFragmentTexture(targets.occlusion, index: 3)
            encoder.setFragmentSamplerState(compareSampler, index: 0)
            encoder.setFragmentSamplerState(pointSampler, index: 1)
            encoder.setFragmentSamplerState(linearSampler, index: 2)
            // Shadow-only ground first; the object then draws over it.
            if !items.isEmpty {
                encoder.setRenderPipelineState(studio.ground)
                encoder.setDepthStencilState(depthAlways)
                encoder.setCullMode(.none)
                encoder.setVertexBytes(&uniforms, length: MemoryLayout<FrameUniforms>.stride, index: 1)
                encoder.setFragmentBytes(&uniforms, length: MemoryLayout<FrameUniforms>.stride, index: 1)
                encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            }
        }
        encoder.setDepthStencilState(depthWrite)
        for item in items where !item.material.isTransparent {
            encoder.setRenderPipelineState(item.cut != nil ? (studio?.cut ?? toonCut) : (studio?.solid ?? toonSolid))
            encoder.setCullMode(cullMode(item))
            draw(item, encoder, uniforms: &uniforms)
        }
        // See-through parts last, far to near, testing but not writing depth.
        encoder.setDepthStencilState(depthRead)
        for item in items.filter(\.material.isTransparent).sorted(by: { $0.depth > $1.depth }) {
            encoder.setRenderPipelineState(item.cut != nil ? (studio?.cut ?? toonCut) : (studio?.solid ?? toonGlass))
            if item.cut == nil, !item.material.doubleSided {
                // Back faces first, then front faces, so a closed glass shape layers correctly.
                encoder.setCullMode(.front)
                draw(item, encoder, uniforms: &uniforms)
                encoder.setCullMode(.back)
            } else {
                encoder.setCullMode(.none)
            }
            draw(item, encoder, uniforms: &uniforms)
        }
        encoder.endEncoding()
    }

    private func encodeIDs(_ items: [FigureDrawItem], uniforms: inout FrameUniforms, into ids: MTLTexture, depth: MTLTexture,
                           commandBuffer: MTLCommandBuffer) {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = ids
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        pass.depthAttachment.texture = depth
        pass.depthAttachment.loadAction = .clear
        pass.depthAttachment.storeAction = .dontCare
        pass.depthAttachment.clearDepth = 1
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.label = "figure ids"
        encoder.setDepthStencilState(depthWrite)
        encoder.setFrontFacing(.counterClockwise)
        for item in items {
            encoder.setRenderPipelineState(item.cut != nil ? idCutPipeline : idPipeline)
            encoder.setCullMode(cullMode(item))
            draw(item, encoder, uniforms: &uniforms)
        }
        encoder.endEncoding()
    }

    private func encodeOutline(uniforms: inout FrameUniforms, ids: MTLTexture, target: MTLTexture, commandBuffer: MTLCommandBuffer) {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .load
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.label = "figure ink"
        encoder.setRenderPipelineState(outlinePipeline)
        encoder.setFragmentTexture(ids, index: 0)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<FrameUniforms>.stride, index: 1)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
    }

    // MARK: - Environment

    private struct EnvParams {
        var room: SIMD4<Float>
        var misc: SIMD4<Float>
        var fill: SIMD4<Float>
    }

    /// Bake the studio once: radiance cube (with mips), pre-blurred reflection levels, and diffuse irradiance.
    private func bakeEnvironment(_ commandBuffer: MTLCommandBuffer, _ studio: StudioPipelines) {
        let s = settings
        func cube(_ size: Int, levels: Int) -> MTLTexture? {
            let d = MTLTextureDescriptor.textureCubeDescriptor(pixelFormat: .rgba16Float, size: size, mipmapped: levels > 1)
            d.mipmapLevelCount = levels
            d.usage = [.shaderRead, .shaderWrite, .renderTarget]
            d.storageMode = .private
            return device.makeTexture(descriptor: d)
        }
        let baseSize = 128
        let baseLevels = Int(log2(Double(baseSize))) + 1
        guard let base = cube(baseSize, levels: baseLevels), let specular = cube(baseSize, levels: specularLevels),
              let irradiance = cube(16, levels: 1), let encoder = commandBuffer.makeComputeCommandEncoder() else { return }
        var params = EnvParams(room: SIMD4(s.room, s.softboxes.x, s.softboxes.y, s.softboxes.z),
                               misc: SIMD4(s.softboxes.w, 0, 128, Float(baseLevels)), fill: SIMD4(s.frontFill, s.bounceCard, 0, 0))
        let group = MTLSize(width: 8, height: 8, depth: 1)
        encoder.setComputePipelineState(studio.envBake)
        encoder.setTexture(base, index: 0)
        encoder.setBytes(&params, length: MemoryLayout<EnvParams>.stride, index: 0)
        encoder.dispatchThreads(MTLSize(width: baseSize, height: baseSize, depth: 6), threadsPerThreadgroup: group)
        encoder.endEncoding()
        if let blit = commandBuffer.makeBlitCommandEncoder() {
            blit.generateMipmaps(for: base)
            blit.endEncoding()
        }
        guard let filter = commandBuffer.makeComputeCommandEncoder() else { return }
        filter.setComputePipelineState(studio.envPrefilter)
        filter.setTexture(base, index: 0)
        filter.setSamplerState(linearSampler, index: 0)
        for level in 0..<specularLevels {
            guard let view = specular.makeTextureView(pixelFormat: .rgba16Float, textureType: .typeCube,
                                                      levels: level..<(level + 1), slices: 0..<6) else { continue }
            params.misc.y = Float(level) / Float(specularLevels - 1)
            params.misc.z = level == 0 ? 1 : 192
            filter.setTexture(view, index: 1)
            filter.setBytes(&params, length: MemoryLayout<EnvParams>.stride, index: 0)
            let size = max(1, baseSize >> level)
            filter.dispatchThreads(MTLSize(width: size, height: size, depth: 6), threadsPerThreadgroup: group)
        }
        filter.setComputePipelineState(studio.envIrradiance)
        filter.setTexture(base, index: 0)
        filter.setTexture(irradiance, index: 1)
        filter.setBytes(&params, length: MemoryLayout<EnvParams>.stride, index: 0)
        filter.dispatchThreads(MTLSize(width: 16, height: 16, depth: 6), threadsPerThreadgroup: group)
        filter.endEncoding()
        environmentBase = base
        environmentSpecular = specular
        environmentIrradiance = irradiance
        environmentBaked = true
    }

    // MARK: - Resources

    private func shadowTexture() -> MTLTexture? {
        if let shadowMap { return shadowMap }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth32Float, width: 2048, height: 2048, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]
        d.storageMode = .private
        shadowMap = device.makeTexture(descriptor: d)
        return shadowMap
    }

    /// Ambient occlusion's side for a frame side: half, rounded up.
    static func halfSide(_ side: Int) -> Int { max(1, (side + 1) / 2) }

    /// The size the occlusion is computed at for a frame of `width` × `height` pixels (tests).
    func occlusionSize(width: Int, height: Int) -> (width: Int, height: Int)? {
        guard let targets = targets(width: width, height: height) else { return nil }
        return (targets.occlusion.width, targets.occlusion.height)
    }

    /// The work textures for one pixel size, or nil if the size is out of range or the GPU can't make them.
    private func targets(width: Int, height: Int) -> Targets? {
        guard width >= 1, height >= 1, CGFloat(max(width, height)) <= Self.maxPixelSide else { return nil }
        if let index = targetCache.firstIndex(where: { $0.width == width && $0.height == height }) {
            let hit = targetCache.remove(at: index)
            targetCache.append(hit)
            return hit
        }
        func texture(_ format: MTLPixelFormat, samples: Int = 1, usage: MTLTextureUsage, shared: Bool = false, half: Bool = false) -> MTLTexture? {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: half ? Self.halfSide(width) : width,
                                                             height: half ? Self.halfSide(height) : height, mipmapped: false)
            d.textureType = samples > 1 ? .type2DMultisample : .type2D
            d.sampleCount = samples
            d.usage = usage
            d.storageMode = shared ? (device.hasUnifiedMemory ? .shared : .managed) : .private
            return device.makeTexture(descriptor: d)
        }
        guard let msaaColor = texture(Self.colorFormat, samples: Self.sampleCount, usage: .renderTarget),
              let msaaDepth = texture(.depth32Float, samples: Self.sampleCount, usage: .renderTarget),
              let ids = texture(.r32Uint, usage: [.renderTarget, .shaderRead], shared: true),
              let idDepth = texture(.depth32Float, usage: .renderTarget),
              let normalDepth = texture(.rgba16Float, usage: [.renderTarget, .shaderRead], half: true),
              let normalDepthDepth = texture(.depth32Float, usage: .renderTarget, half: true),
              let occlusionRaw = texture(.r16Float, usage: [.renderTarget, .shaderRead], half: true),
              let occlusion = texture(.r16Float, usage: [.renderTarget, .shaderRead], half: true) else { return nil }
        let made = Targets(
            width: width, height: height, msaaColor: msaaColor, msaaDepth: msaaDepth, ids: ids, idDepth: idDepth,
            normalDepth: normalDepth, normalDepthDepth: normalDepthDepth, occlusionRaw: occlusionRaw, occlusion: occlusion)
        targetCache.append(made)
        if targetCache.count > 4 { targetCache.removeFirst() }
        return made
    }

    private func buffers(for mesh: FigureMesh) -> MeshBuffers? {
        let key = ObjectIdentifier(mesh)
        if let existing = meshBuffers[key], existing.owner === mesh { return existing }
        if meshBuffers.count > 512 { meshBuffers = meshBuffers.filter { $0.value.owner != nil } }
        guard !mesh.indices.isEmpty,
              let vertices = mesh.vertices.withUnsafeBytes({ device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared) }),
              let indices = mesh.indices.withUnsafeBytes({ device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared) })
        else { return nil }
        let buffers = MeshBuffers(owner: mesh, vertices: vertices, indices: indices, count: mesh.indices.count)
        meshBuffers[key] = buffers
        return buffers
    }

    private func synchronize(_ texture: MTLTexture, _ commandBuffer: MTLCommandBuffer) {
        guard texture.storageMode == .managed, let blit = commandBuffer.makeBlitCommandEncoder() else { return }
        blit.synchronize(resource: texture)
        blit.endEncoding()
    }
}
