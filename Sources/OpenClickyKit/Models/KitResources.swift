import Foundation

/// Files shipped in OpenClickyKit's resource bundle (JavaScript engines, Metal shader source, catalogs).
/// Works both under `swift run`/`swift test` and inside OpenClicky.app, where the bundle lives in Contents/Resources.
public enum KitResources {
    /// URL of `subdirectory/name.ext`, e.g. `url("draw-engine", "js", in: "js")`.
    public static func url(_ name: String, _ ext: String, in subdirectory: String? = nil) -> URL? {
        for bundle in bundles {
            if let url = bundle.url(forResource: name, withExtension: ext, subdirectory: subdirectory) { return url }
        }
        return nil
    }

    public static func text(_ name: String, _ ext: String, in subdirectory: String? = nil) throws -> String {
        guard let url = url(name, ext, in: subdirectory) else { throw CocoaError(.fileNoSuchFile) }
        return try String(contentsOf: url, encoding: .utf8)
    }

    private static var bundles: [Bundle] {
        var result: [Bundle] = []
        if let url = Bundle.main.url(forResource: "OpenClicky_OpenClickyKit", withExtension: "bundle"), let bundle = Bundle(url: url) {
            result.append(bundle)
        }
        result.append(Bundle.module)
        return result
    }
}
