import Foundation
import JavaScriptCore

public enum FigureKernelError: Error, CustomStringConvertible, Equatable {
    case loadFailed(String)
    case buildFailed(kind: String, message: String)

    public var description: String {
        switch self {
        case .loadFailed(let message): "3D kernel failed to load: \(message)"
        case .buildFailed(let kind, let message): "3D kernel: \(kind) failed: \(message)"
        }
    }
}

/// Builds part meshes from recipes in its own JavaScriptCore context (three-slice.js + three-kernel.js), on a
/// private serial queue, never on the drawing engine's context or the main thread.
///
/// Results are cached by kind + canonical recipe JSON (key order does not matter) in a byte-budgeted LRU. Identical
/// requests in flight are built once, and a recipe that failed is not retried. The context is released after a quiet
/// period and rebuilt on the next request.
public final class FigureKernel: @unchecked Sendable {
    public static let shared = FigureKernel()

    public struct Stats: Sendable, Equatable {
        public var hits = 0
        public var misses = 0
        public var builds = 0
        public var failures = 0
        public var cachedMeshes = 0
        public var cachedBytes = 0
    }

    public typealias Completion = @Sendable (Result<FigureMesh, FigureKernelError>) -> Void

    private let queue = DispatchQueue(label: "openclicky.figure-kernel", qos: .userInitiated)
    private let lock = NSLock()
    private let byteBudget: Int
    private let idleRelease: TimeInterval

    // Guarded by `lock`.
    private var cache: [String: FigureMesh] = [:]
    private var useOrder: [String] = []
    private var cachedBytes = 0
    private var failed: [String: FigureKernelError] = [:]
    private var waiting: [String: [Completion]] = [:]
    private var stats = Stats()

    // Only touched on `queue`.
    private var context: JSContext?
    private var buildFunction: JSValue?
    private var lastError: String?
    private var idleGeneration = 0
    private var kindList: [String] = []

    public init(byteBudget: Int = 160 << 20, idleRelease: TimeInterval = 90) {
        self.byteBudget = byteBudget
        self.idleRelease = idleRelease
    }

    /// Cache key: kind + canonical recipe JSON, so `{"r":1,"h":2}` and `{"h":2,"r":1}` share a mesh.
    public static func key(kind: String, recipe: String) -> String {
        let canonical = (try? JSONValue.parse(recipe.isEmpty ? "{}" : recipe).jsonString()) ?? recipe
        return kind + "\u{1}" + canonical
    }

    public var currentStats: Stats {
        lock.lock(); defer { lock.unlock() }
        var copy = stats
        copy.cachedMeshes = cache.count
        copy.cachedBytes = cachedBytes
        return copy
    }

    /// The mesh if it is already built (counts as a hit).
    public func cachedMesh(kind: String, recipe: String) -> FigureMesh? {
        let key = Self.key(kind: kind, recipe: recipe)
        lock.lock(); defer { lock.unlock() }
        guard let mesh = cache[key] else { return nil }
        stats.hits += 1
        touch(key)
        return mesh
    }

    /// Start building so the mesh is ready when the part's beat is drawn.
    public func prewarm(kind: String, recipe: String) {
        mesh(kind: kind, recipe: recipe) { _ in }
    }

    /// Build (or fetch) a mesh. `completion` runs on the kernel queue, or immediately on a cache hit.
    public func mesh(kind: String, recipe: String, completion: @escaping Completion) {
        let key = Self.key(kind: kind, recipe: recipe)
        lock.lock()
        if let mesh = cache[key] {
            stats.hits += 1
            touch(key)
            lock.unlock()
            completion(.success(mesh))
            return
        }
        if let error = failed[key] {
            lock.unlock()
            completion(.failure(error))
            return
        }
        stats.misses += 1
        if waiting[key] != nil {
            waiting[key]!.append(completion)
            lock.unlock()
            return
        }
        waiting[key] = [completion]
        lock.unlock()

        queue.async { [self] in
            let result = build(kind: kind, recipe: recipe)
            lock.lock()
            switch result {
            case .success(let mesh): store(mesh, for: key)
            case .failure(let error):
                failed[key] = error
                stats.failures += 1
            }
            let callbacks = waiting.removeValue(forKey: key) ?? []
            lock.unlock()
            callbacks.forEach { $0(result) }
            scheduleIdleRelease()
        }
    }

    public func mesh(kind: String, recipe: String) async throws -> FigureMesh {
        try await withCheckedThrowingContinuation { continuation in
            mesh(kind: kind, recipe: recipe) { continuation.resume(with: $0) }
        }
    }

    /// Blocking build, for offscreen rendering and tests. Never call it on the kernel queue.
    public func meshNow(kind: String, recipe: String) throws -> FigureMesh {
        if let mesh = cachedMesh(kind: kind, recipe: recipe) { return mesh }
        let semaphore = DispatchSemaphore(value: 0)
        let box = ResultBox()
        mesh(kind: kind, recipe: recipe) { result in
            box.result = result
            semaphore.signal()
        }
        semaphore.wait()
        return try box.result!.get()
    }

    /// The part kinds the kernel builds.
    public func kinds() throws -> [String] {
        try queue.sync {
            try loadIfNeeded()
            return kindList
        }
    }

    /// Drop every cached mesh and failure (for tests and memory pressure).
    public func purge() {
        lock.lock()
        cache.removeAll()
        useOrder.removeAll()
        cachedBytes = 0
        failed.removeAll()
        stats = Stats()
        lock.unlock()
    }

    // MARK: - Cache (call with `lock` held)

    private func touch(_ key: String) {
        if let index = useOrder.lastIndex(of: key) { useOrder.remove(at: index) }
        useOrder.append(key)
    }

    private func store(_ mesh: FigureMesh, for key: String) {
        stats.builds += 1
        cache[key] = mesh
        cachedBytes += mesh.byteSize
        touch(key)
        while cachedBytes > byteBudget, useOrder.count > 1 {
            let oldest = useOrder.removeFirst()
            if let evicted = cache.removeValue(forKey: oldest) { cachedBytes -= evicted.byteSize }
        }
    }

    // MARK: - JavaScript (kernel queue only)

    private func loadIfNeeded() throws {
        if buildFunction != nil { return }
        guard let context = JSContext() else { throw FigureKernelError.loadFailed("could not create a JavaScript context") }
        context.name = "OpenClicky 3D kernel"
        context.exceptionHandler = { [weak self] _, exception in
            self?.lastError = exception?.toString()
        }
        for name in ["three-slice", "three-kernel"] {
            guard let source = try? KitResources.text(name, "js", in: "js") else {
                throw FigureKernelError.loadFailed("\(name).js is missing")
            }
            lastError = nil
            context.evaluateScript(source, withSourceURL: URL(string: "openclicky://js/\(name).js"))
            if let error = lastError { throw FigureKernelError.loadFailed("\(name).js failed to load: \(error)") }
        }
        guard let build = context.objectForKeyedSubscript("ocKernelBuild"), build.isObject else {
            throw FigureKernelError.loadFailed("ocKernelBuild is missing")
        }
        kindList = context.objectForKeyedSubscript("ocKernelKinds")?.toArray()?.compactMap { $0 as? String } ?? []
        self.context = context
        self.buildFunction = build
    }

    private func build(kind: String, recipe: String) -> Result<FigureMesh, FigureKernelError> {
        do {
            try loadIfNeeded()
        } catch let error as FigureKernelError {
            return .failure(error)
        } catch {
            return .failure(.loadFailed("\(error)"))
        }
        guard let context, let buildFunction else { return .failure(.loadFailed("no context")) }
        lastError = nil
        let value = buildFunction.call(withArguments: [kind, recipe])
        if let error = lastError { return .failure(.buildFailed(kind: kind, message: error)) }
        guard let value, value.isObject else { return .failure(.buildFailed(kind: kind, message: "no result")) }
        let positions = Self.floats(value.objectForKeyedSubscript("positions"), in: context)
        let normals = Self.floats(value.objectForKeyedSubscript("normals"), in: context)
        let uvs = Self.floats(value.objectForKeyedSubscript("uvs"), in: context)
        let samples = Self.floats(value.objectForKeyedSubscript("samples"), in: context)
        let indices = Self.uints(value.objectForKeyedSubscript("indices"), in: context)
        let bounds = (value.objectForKeyedSubscript("bounds")?.toArray() ?? []).compactMap { ($0 as? NSNumber)?.floatValue }
        guard !positions.isEmpty, !indices.isEmpty else { return .failure(.buildFailed(kind: kind, message: "empty mesh")) }
        return .success(FigureMesh(positions: positions, normals: normals, uvs: uvs, indices: indices, samples: samples, bounds: bounds))
    }

    private func scheduleIdleRelease() {
        idleGeneration += 1
        let generation = idleGeneration
        queue.asyncAfter(deadline: .now() + idleRelease) { [weak self] in
            guard let self, self.idleGeneration == generation else { return }
            self.context = nil
            self.buildFunction = nil
        }
    }

    // MARK: - Typed arrays

    static func floats(_ value: JSValue?, in context: JSContext) -> [Float] {
        typedArray(value, in: context, type: kJSTypedArrayTypeFloat32Array, as: Float.self)
    }

    static func uints(_ value: JSValue?, in context: JSContext) -> [UInt32] {
        typedArray(value, in: context, type: kJSTypedArrayTypeUint32Array, as: UInt32.self)
    }

    private static func typedArray<T>(_ value: JSValue?, in context: JSContext, type: JSTypedArrayType, as: T.Type) -> [T] {
        guard let value, value.isObject else { return [] }
        let ctx = context.jsGlobalContextRef
        var exception: JSValueRef?
        guard JSValueGetTypedArrayType(ctx, value.jsValueRef, &exception) == type,
              let object = JSValueToObject(ctx, value.jsValueRef, &exception) else { return [] }
        let count = JSObjectGetTypedArrayLength(ctx, object, &exception)
        // The bytes pointer is the start of the whole ArrayBuffer, not of this view: a subarray starts byteOffset in.
        let offset = JSObjectGetTypedArrayByteOffset(ctx, object, &exception)
        guard count > 0, let bytes = JSObjectGetTypedArrayBytesPtr(ctx, object, &exception) else { return [] }
        let typed = (bytes + offset).bindMemory(to: T.self, capacity: count)
        return Array(UnsafeBufferPointer(start: typed, count: count))
    }
}

private final class ResultBox: @unchecked Sendable {
    var result: Result<FigureMesh, FigureKernelError>?
}
