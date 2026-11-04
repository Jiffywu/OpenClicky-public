import AppKit
import CoreGraphics
import Foundation
import Metal
import QuartzCore
import simd

/// A click on a figure part, ready to become a typed follow-up turn for the brain.
public struct FigureClick: Sendable, Equatable {
    public var figureID: String
    public var partID: String
    /// How the part is referred to: `the part labelled "rotor"`, `the crank`, `this steel gear`.
    public var name: String
    public var isLabelled: Bool

    public init(figureID: String, partID: String, name: String, isLabelled: Bool) {
        self.figureID = figureID
        self.partID = partID
        self.name = name
        self.isLabelled = isLabelled
    }

    /// The question the click asks.
    public var question: String { "Tell me about \(name) in the 3D figure you just drew." }
}

/// What is under the pointer, so the host can pick a cursor (open hand over the figure, pointing hand over a part).
public enum FigureHover: Sendable, Equatable {
    case none
    case figure
    case part(String)
}

/// Shows figures live. The 2D painter forwards every 3D mark here (`FigureSink`) and places the returned layer at the
/// figure's rectangle; each figure gets its own `CAMetalLayer` with a label overlay above it.
///
/// Parts are built by the geometry kernel off the main thread and grow in when their mesh arrives. Frames come from the
/// display's display link while any figure exists (a timer when there is no screen; or call `renderFrame(at:)`): at
/// `framesPerSecond` while something moves, at `turntableFramesPerSecond` while only the turntable turns, and slower
/// still while every figure is still (nothing is redrawn then). The turntable turns by itself; the host
/// forwards pointer events (`pointerDown`, `pointerDragged`, `pointerUp`) so a drag turns the figure and a click on a
/// part becomes a `FigureClick`. Points are in the figure layer's coordinates with a top-left origin.
@MainActor
public final class FigureStage: FigureSink {
    public struct Settings: Sendable {
        /// Degrees the figure turns per point of drag.
        public var dragDegreesPerPoint: Float = 0.45
        /// Pointer travel (points) beyond which a press is a drag rather than a click.
        public var clickSlop: CGFloat = 4
        /// Seconds after the user lets go before the turntable starts again.
        public var resumeAfterDrag: Double = 2.5
        /// Pixels per point of the figure layers.
        public var contentsScale: CGFloat = 2
        /// Frames per second while parts move, grow in or follow the user's hand.
        public var framesPerSecond: Double = 60
        /// Frames per second while the only thing moving is the slow turntable: it looks as smooth at half the rate.
        public var turntableFramesPerSecond: Double = 30
        /// How often the stage checks for work while every figure is still.
        public var idleFramesPerSecond: Double = 15

        public init() {}
    }

    public var settings = Settings()
    public let kernel: FigureKernel
    /// Draw every figure in this look instead of the one its program chose.
    public var lookOverride: FigureLook?
    /// Runs a figure's started ticks: (figure id, [(tick id, seconds since its line started)], dt) -> packed poses.
    /// Wire it to `FigureTickBridge.runTicks` on the drawing engine's context.
    public var tickProvider: ((String, [(String, Double)], Double) -> [Float])?
    /// Readouts that ticks changed since the last frame: figure id -> key -> text (`FigureTickBridge.takeReadouts`).
    public var readoutProvider: (() -> [String: [String: String]])?
    /// The program variable holding a part (`__figure3d.nameOf`), used to name unlabelled clicked parts.
    public var variableName: ((String) -> String?)?
    public var onPartClicked: ((FigureClick) -> Void)?
    /// Problems worth logging: a part that failed to build, the GPU being unavailable.
    public var onWarning: ((String) -> Void)?
    /// Draw frames on a timer (default). Tests and offscreen hosts turn it off and call `renderFrame(at:)`.
    public var drivesItself: Bool {
        didSet { updateDriver() }
    }

    public private(set) var renderer: FigureRenderer?
    /// Set when this Mac can't show figures at all (no Metal device, or the shaders failed to compile).
    public private(set) var rendererError: Error?
    public var figureIDs: [String] { order }
    /// The display the figures are on, so frames follow its refresh (`CGDirectDisplayID`); nil uses the main screen.
    public var displayID: UInt32? {
        didSet { if displayID != oldValue { restartDriver() } }
    }
    /// The frame rate the stage asks of its driver now (0 with no figures).
    public private(set) var requestedFramesPerSecond: Double = 0
    /// Makes the renderer (tests swap in one whose studio shaders fail).
    var makeRenderer: (MTLDevice?) throws -> FigureRenderer = { try FigureRenderer(device: $0) }

    private let device: MTLDevice?
    private let clock: () -> CFTimeInterval
    private var figures: [String: Figure] = [:]
    private var order: [String] = []
    private var orphans: [String: [DrawingMark]] = [:]
    /// Mesh loads still running, by a serial number; each removes itself when it finishes.
    private var loads: [Int: Task<Void, Never>] = [:]
    private var loadSerial = 0
    /// Mesh loads still running (for tests).
    var pendingLoads: Int { loads.count }
    private var driver: FigureFrameDriver?
    private var lastFrameTime: CFTimeInterval?

    final class Figure {
        let scene: FigureScene
        let container: CALayer
        let metal: CAMetalLayer
        let overlay: CALayer
        var fitCenter: SIMD3<Float>?
        var fitRadius: Float = 0
        var lastFrame: FigureFrame?
        var overlayKey: [FigureLabelPlacement] = []
        var overlayReadouts: [String] = []
        var press: CGPoint?
        var lastPoint = CGPoint.zero
        var travel: CGFloat = 0
        var dragging = false
        var lastHandTime: CFTimeInterval = -.infinity
        var drewObject = false
        /// Draw every frame until then even if nothing seems to move (new marks, a resize, settling framing).
        var busyUntil: CFTimeInterval = 0
        var lastSize = CGSize.zero
        /// When the figure was last drawn, and how many times (tests).
        var lastDrawTime: CFTimeInterval?
        var drawCount = 0

        init(scene: FigureScene, container: CALayer, metal: CAMetalLayer, overlay: CALayer) {
            self.scene = scene
            self.container = container
            self.metal = metal
            self.overlay = overlay
        }
    }

    public init(kernel: FigureKernel = .shared, device: MTLDevice? = nil, drivesItself: Bool = true,
                clock: @escaping () -> CFTimeInterval = { CACurrentMediaTime() }) {
        self.kernel = kernel
        self.device = device
        self.clock = clock
        self.drivesItself = drivesItself
    }

    // MARK: - FigureSink

    public func apply(_ mark: DrawingMark) {
        guard mark.isFigureMark else { return }
        let at = time(of: mark)
        if mark.kind == "figure" {
            if let existing = figures[mark.id] {
                existing.scene.apply(mark, at: at)
                existing.container.frame = existing.scene.rect
                return
            }
            let scene = FigureScene(mark: mark, at: at)
            if let lookOverride { scene.setLook(lookOverride) }
            figures[mark.id] = makeFigure(scene)
            order.append(mark.id)
            for orphan in orphans.removeValue(forKey: mark.id) ?? [] { apply(orphan) }
            updateDriver()
            return
        }
        guard let figureID = mark.json["figure"]?.stringValue else { return }
        guard let figure = figures[figureID] else {
            // A mark that overtook its figure waits for it.
            orphans[figureID, default: []].append(mark)
            return
        }
        if let node = figure.scene.apply(mark, at: at) { load(node, in: figure) }
        // Keep drawing through the mark's animation (grow-in, label writing, a glide) and a little after.
        let secs = max(mark.duration, mark.json["secs"]?.doubleValue ?? 0)
        figure.busyUntil = max(figure.busyUntil, at + secs + 1.5)
    }

    public func layer(forFigure figureID: String) -> CALayer? { figures[figureID]?.container }

    public func hitTest(figure figureID: String, at point: CGPoint) -> String? {
        guard let figure = figures[figureID], let renderer else { return nil }
        let frame = figure.lastFrame ?? currentFrame(figure, at: clock())
        let id = renderer.pick(frame, scale: settings.contentsScale, at: point)
        guard id != 0 else { return nil }
        return figure.scene.node(number: Int(id))?.id
    }

    public func removeFigure(_ figureID: String) {
        guard let figure = figures.removeValue(forKey: figureID) else { return }
        figure.container.removeFromSuperlayer()
        order.removeAll { $0 == figureID }
        orphans[figureID] = nil
        updateDriver()
    }

    /// Remove every figure.
    public func removeAll() {
        for id in order { removeFigure(id) }
    }

    /// The scene model of a figure (parts, labels, camera), for hosts and tests.
    public func scene(_ figureID: String) -> FigureScene? { figures[figureID]?.scene }

    func figure(_ figureID: String) -> Figure? { figures[figureID] }

    /// Wait until every part requested so far has its mesh (or has failed).
    public func settle() async {
        while let task = loads.values.first {
            await task.value
        }
    }

    // MARK: - Pointer

    public func pointerDown(figure figureID: String, at point: CGPoint) {
        guard let figure = figures[figureID] else { return }
        figure.press = point
        figure.lastPoint = point
        figure.travel = 0
        figure.dragging = false
    }

    public func pointerDragged(figure figureID: String, to point: CGPoint) {
        guard let figure = figures[figureID], figure.press != nil else { return }
        let dx = point.x - figure.lastPoint.x, dy = point.y - figure.lastPoint.y
        figure.travel += hypot(dx, dy)
        figure.lastPoint = point
        if figure.travel > settings.clickSlop { figure.dragging = true }
        guard figure.dragging else { return }
        let scene = figure.scene
        // Dragging right turns the front of the object to the right (the camera goes left); dragging down tips it
        // toward the viewer (the camera rises).
        scene.dragYaw -= Float(dx) * settings.dragDegreesPerPoint
        let baseTilt = scene.camera(at: clock()).tilt
        scene.dragTilt = min(80 - baseTilt, max(-80 - baseTilt, scene.dragTilt + Float(dy) * settings.dragDegreesPerPoint))
        figure.lastHandTime = clock()
    }

    /// Ends a press. A press that did not travel is a click: the part under it is picked, briefly highlighted and
    /// reported through `onPartClicked`.
    @discardableResult
    public func pointerUp(figure figureID: String, at point: CGPoint) -> FigureClick? {
        guard let figure = figures[figureID], figure.press != nil else { return nil }
        let wasDrag = figure.dragging
        figure.press = nil
        figure.dragging = false
        figure.lastHandTime = clock()
        guard !wasDrag, let partID = hitTest(figure: figureID, at: point) else { return nil }
        let described = figure.scene.clickName(for: partID, variableName: variableName)
        figure.scene.highlighted = (partID, clock())
        let click = FigureClick(figureID: figureID, partID: partID, name: described.name, isLabelled: described.isLabelled)
        onPartClicked?(click)
        return click
    }

    public func hover(figure figureID: String, at point: CGPoint) -> FigureHover {
        guard let figure = figures[figureID], CGRect(origin: .zero, size: viewport(figure)).contains(point) else { return .none }
        if let part = hitTest(figure: figureID, at: point) { return .part(part) }
        return .figure
    }

    // MARK: - Frames

    /// Advance and draw every figure once.
    public func renderFrame(at time: CFTimeInterval? = nil) {
        let now = time ?? clock()
        let dt = lastFrameTime.map { min(0.1, max(1.0 / 240, now - $0)) } ?? 1.0 / 60
        lastFrameTime = now
        for id in order {
            guard let figure = figures[id] else { continue }
            runTicks(figure, at: now, dt: dt)
        }
        if let values = readoutProvider?() {
            for (id, readouts) in values { figures[id]?.scene.applyReadouts(readouts) }
        }
        for id in order {
            guard let figure = figures[id] else { continue }
            draw(figure, at: now, dt: dt)
        }
    }

    /// The figure as it looks now, rendered offscreen (for tests, previews and screenshots of the stage).
    public func image(figure figureID: String, background: SIMD4<Float>? = nil) throws -> CGImage? {
        guard let figure = figures[figureID] else { return nil }
        guard let renderer = try ensureRenderer() else { throw rendererError ?? FigureRendererError.noDevice }
        let frame = figure.lastFrame ?? currentFrame(figure, at: clock())
        let image = try renderer.renderImage(frame, scale: settings.contentsScale, background: background)
        return try FigureSnapshot.compose(image, frame: frame, scene: figure.scene, time: clock(),
                                          options: { var o = FigureSnapshot.Options(); o.scale = settings.contentsScale; o.background = nil; return o }())
    }

    // MARK: - Internals

    private func time(of mark: DrawingMark) -> CFTimeInterval {
        // The engine stamps each mark with its line's start (`base`, on the host clock) and its offset (`start`).
        (mark.json["base"]?.doubleValue ?? clock()) + mark.start
    }

    private func ensureRenderer() throws -> FigureRenderer? {
        if let renderer { return renderer }
        if rendererError != nil { return nil }
        do {
            let made = try makeRenderer(device)
            renderer = made
            if let studioError = made.studioError {
                // Not fatal: studio figures are drawn in the illustrated look.
                onWarning?("studio look unavailable, drawing figures illustrated instead (\(studioError))")
            }
            return made
        } catch {
            rendererError = error
            onWarning?("\(error)")
            return nil
        }
    }

    private func makeFigure(_ scene: FigureScene) -> Figure {
        let renderer = try? ensureRenderer()
        let scale = settings.contentsScale
        let quiet: [String: any CAAction] = ["bounds": NSNull(), "position": NSNull(), "contents": NSNull(), "frame": NSNull()]
        let container = CALayer()
        container.name = scene.id
        container.frame = scene.rect
        container.actions = quiet
        let metal = CAMetalLayer()
        metal.device = renderer?.device
        metal.pixelFormat = FigureRenderer.colorFormat
        metal.isOpaque = false
        metal.framebufferOnly = true
        metal.contentsScale = scale
        metal.actions = quiet
        let overlay = CALayer()
        overlay.contentsScale = scale
        overlay.actions = quiet
        container.addSublayer(metal)
        container.addSublayer(overlay)
        let figure = Figure(scene: scene, container: container, metal: metal, overlay: overlay)
        fitLayers(figure)
        return figure
    }

    private func viewport(_ figure: Figure) -> CGSize {
        let size = figure.container.bounds.size
        return size.width >= 1 && size.height >= 1 ? size : figure.scene.rect.size
    }

    private func fitLayers(_ figure: Figure) {
        let size = viewport(figure)
        let bounds = CGRect(origin: .zero, size: size)
        if figure.metal.frame != bounds { figure.metal.frame = bounds }
        if figure.overlay.frame != bounds { figure.overlay.frame = bounds }
        // A figure too big for a GPU texture at full scale gets a lower-resolution drawable, stretched to fit.
        let (width, height) = FigureRenderer.pixelSize(viewport: size, scale: settings.contentsScale)
        let pixels = CGSize(width: width, height: height)
        if figure.metal.drawableSize != pixels { figure.metal.drawableSize = pixels }
    }

    private func load(_ node: FigureNode, in figure: Figure) {
        guard let recipe = node.recipe else { return }
        if let mesh = kernel.cachedMesh(kind: node.kind, recipe: recipe) {
            node.mesh = mesh
            return
        }
        let kernel = self.kernel, kind = node.kind, figureID = figure.scene.id, nodeID = node.id
        figure.busyUntil = max(figure.busyUntil, clock() + 2)
        loadSerial += 1
        let serial = loadSerial
        let task = Task { @MainActor [weak self] in
            let result: Result<FigureMesh, any Error>
            do { result = .success(try await kernel.mesh(kind: kind, recipe: recipe)) } catch { result = .failure(error) }
            self?.loads[serial] = nil
            guard let self, let node = self.figures[figureID]?.scene.node(nodeID) else { return }
            switch result {
            case .success(let mesh):
                node.mesh = mesh
                // A part whose mesh came late grows in from now, not part-way through.
                node.appearAt = max(node.appearAt, self.clock())
                if let figure = self.figures[figureID] { figure.busyUntil = max(figure.busyUntil, node.appearAt + 2) }
            case .failure(let error):
                node.meshError = "\(error)"
                self.onWarning?("\(error)")
            }
        }
        // The task runs on the main actor, so it can't finish (and remove itself) before this line.
        loads[serial] = task
    }

    private func runTicks(_ figure: Figure, at now: CFTimeInterval, dt: Double) {
        guard let tickProvider else { return }
        let started = figure.scene.ticks.filter { $0.start <= now }
        guard !started.isEmpty else { return }
        figure.scene.applyTickPoses(tickProvider(figure.scene.id, started.map { ($0.id, now - $0.start) }, dt))
    }

    private func currentFrame(_ figure: Figure, at now: CFTimeInterval) -> FigureFrame {
        let framing = figure.fitCenter.map { (center: $0, radius: max(figure.fitRadius, 0.05)) }
        return figure.scene.frame(at: now, viewport: viewport(figure), framing: framing)
    }

    /// How often a figure needs drawing.
    enum FrameDemand: Int, Comparable {
        /// Nothing can change: the figure isn't redrawn, which keeps an idle figure from costing GPU time.
        case still
        /// Only the turntable turns: drawn at `turntableFramesPerSecond`.
        case turntable
        /// Parts move, grow in or follow the user's hand: drawn at `framesPerSecond`.
        case moving

        static func < (a: FrameDemand, b: FrameDemand) -> Bool { a.rawValue < b.rawValue }
    }

    /// Whether anything in the figure can change this frame.
    func isAnimating(_ figure: Figure, at now: CFTimeInterval) -> Bool { demand(figure, at: now) != .still }

    func demand(_ figure: Figure, at now: CFTimeInterval) -> FrameDemand {
        if isMoving(figure, at: now) { return .moving }
        return figure.scene.camera(at: now).spin > 0 ? .turntable : .still
    }

    /// The frame rate a demand asks for.
    func framesPerSecond(for demand: FrameDemand) -> Double {
        switch demand {
        case .still: settings.idleFramesPerSecond
        case .turntable: min(settings.turntableFramesPerSecond, settings.framesPerSecond)
        case .moving: settings.framesPerSecond
        }
    }

    private func isMoving(_ figure: Figure, at now: CFTimeInterval) -> Bool {
        let scene = figure.scene
        if now < figure.busyUntil || figure.dragging || figure.press != nil { return true }
        if now - figure.lastHandTime < settings.resumeAfterDrag + 1.5 { return true }
        if viewport(figure) != figure.lastSize { return true }
        if !scene.ticks.isEmpty { return true }
        if let highlight = scene.highlighted, now - highlight.since < 1.5 { return true }
        for node in scene.nodes {
            for motion in node.motions where motion.start <= now + 0.1 {
                switch motion.kind {
                case .path where motion.once:
                    if now < motion.start + Double(motion.period) + 0.1 { return true }
                case .spin, .orbit, .swing, .bob, .pulse, .path:
                    if !node.motions.contains(where: { $0.kind == .stop && $0.start <= now && $0.start >= motion.start }) { return true }
                case .glide:
                    if now < motion.start + motion.secs + 0.1 { return true }
                case .set, .stop:
                    break
                }
            }
        }
        return false
    }

    private func draw(_ figure: Figure, at now: CFTimeInterval, dt: Double) {
        let scene = figure.scene
        if figure.lastFrame != nil {
            let demand = demand(figure, at: now)
            guard demand != .still else { return }
            // A turntable-only figure skips frames to hold its lower rate, whatever the display link delivers.
            if demand == .turntable, let last = figure.lastDrawTime, now - last < 1 / framesPerSecond(for: .turntable) - 0.002 { return }
        }
        figure.lastDrawTime = now
        figure.drawCount += 1
        figure.lastSize = viewport(figure)
        let handled = figure.dragging || now - figure.lastHandTime < settings.resumeAfterDrag
        scene.advance(to: now, paused: handled)
        // The fit glides: it widens quickly when a part sticks out and narrows slowly, so the zoom never pumps.
        if let target = scene.framing(at: now) {
            if let center = figure.fitCenter {
                let k = Float(1 - exp(-dt * 4))
                let grow = Float(1 - exp(-dt * 10))
                figure.fitCenter = center + (target.center - center) * k
                figure.fitRadius += (target.radius - figure.fitRadius) * (target.radius > figure.fitRadius ? grow : k)
            } else {
                figure.fitCenter = target.center
                figure.fitRadius = target.radius
            }
        }
        fitLayers(figure)
        let frame = currentFrame(figure, at: now)
        figure.lastFrame = frame
        if let renderer, !frame.items.isEmpty || figure.drewObject {
            figure.drewObject = !frame.items.isEmpty
            if let drawable = figure.metal.nextDrawable(), let commandBuffer = renderer.queue.makeCommandBuffer() {
                commandBuffer.label = "figure \(scene.id)"
                renderer.encode(frame, scale: settings.contentsScale, into: drawable.texture, commandBuffer: commandBuffer)
                commandBuffer.present(drawable)
                commandBuffer.commit()
            }
        }
        drawOverlay(figure, frame: frame, at: now)
    }

    private func drawOverlay(_ figure: Figure, frame: FigureFrame, at now: CFTimeInterval) {
        let scene = figure.scene
        let placements = FigureLabelLayout.layout(scene.labels, frame: frame, time: now)
        let readouts = scene.readouts.map { "\($0.key)\u{1}\($0.value)" }
        guard placements != figure.overlayKey || readouts != figure.overlayReadouts else { return }
        figure.overlayKey = placements
        figure.overlayReadouts = readouts
        guard !placements.isEmpty || !readouts.isEmpty else {
            figure.overlay.contents = nil
            return
        }
        let size = frame.viewport
        let scale = FigureRenderer.effectiveScale(for: size, scale: settings.contentsScale)
        let (width, height) = FigureRenderer.pixelSize(viewport: size, scale: settings.contentsScale)
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: scale, y: -scale)
        let ink = frame.ink
        let inkColor = CGColor(srgbRed: CGFloat(ink.x), green: CGFloat(ink.y), blue: CGFloat(ink.z), alpha: 1)
        // A halo in the opposite tone keeps labels readable over a busy screen.
        let light = 0.2126 * ink.x + 0.7152 * ink.y + 0.0722 * ink.z > 0.5
        let halo = light ? CGColor(gray: 0, alpha: 0.55) : CGColor(gray: 1, alpha: 0.8)
        FigureLabelLayout.draw(placements, readouts: scene.readouts, ink: inkColor, halo: halo, in: context)
        figure.overlay.contents = context.makeImage()
    }

    /// The rate the figures need now: the fastest any of them asks for.
    func neededFramesPerSecond(at now: CFTimeInterval) -> Double {
        guard !figures.isEmpty else { return 0 }
        let demand = figures.values.map { $0.lastFrame == nil ? .moving : demand($0, at: now) }.max() ?? .still
        return framesPerSecond(for: demand)
    }

    /// One tick of the driver: draw, then ask for the rate the next frames need.
    private func driverTick() {
        renderFrame()
        let wanted = neededFramesPerSecond(at: clock())
        if wanted != requestedFramesPerSecond {
            requestedFramesPerSecond = wanted
            driver?.setFramesPerSecond(wanted)
        }
    }

    private func updateDriver() {
        let wanted = drivesItself && !figures.isEmpty
        if wanted, driver == nil {
            requestedFramesPerSecond = settings.framesPerSecond
            driver = FigureFrameDriver(displayID: displayID, framesPerSecond: requestedFramesPerSecond) { [weak self] in self?.driverTick() }
        } else if !wanted, let driver {
            driver.invalidate()
            self.driver = nil
            requestedFramesPerSecond = 0
        }
    }

    private func restartDriver() {
        driver?.invalidate()
        driver = nil
        updateDriver()
    }
}

/// Calls `tick` on the main thread once per frame: from the display's `CADisplayLink` (macOS 14), so frames line up
/// with the screen's refresh, or from a timer when there is no screen (a headless session).
@MainActor
final class FigureFrameDriver: NSObject {
    private let tick: @MainActor () -> Void
    private var link: CADisplayLink?
    private var timer: Timer?
    private(set) var framesPerSecond: Double

    init(displayID: UInt32?, framesPerSecond: Double, tick: @escaping @MainActor () -> Void) {
        self.tick = tick
        self.framesPerSecond = framesPerSecond
        super.init()
        let screen = NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == displayID }
            ?? NSScreen.main
        if let screen {
            let link = screen.displayLink(target: self, selector: #selector(step(_:)))
            link.add(to: .main, forMode: .common)
            self.link = link
            setFramesPerSecond(framesPerSecond)
        } else {
            startTimer()
        }
    }

    @objc private func step(_ link: CADisplayLink) { tick() }

    func setFramesPerSecond(_ fps: Double) {
        framesPerSecond = max(1, fps)
        if let link {
            let rate = Float(framesPerSecond)
            link.preferredFrameRateRange = CAFrameRateRange(minimum: min(rate, 10), maximum: rate, preferred: rate)
        } else if timer != nil {
            startTimer()
        }
    }

    private func startTimer() {
        timer?.invalidate()
        let timer = Timer(timeInterval: 1 / framesPerSecond, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func invalidate() {
        link?.invalidate()
        link = nil
        timer?.invalidate()
        timer = nil
    }
}
