import Foundation
import simd

/// How a part's surface looks. Colours are linear-light RGB.
public struct FigureMaterial: Sendable, Hashable {
    public var color: SIMD3<Float>
    public var roughness: Float
    public var metalness: Float
    public var opacity: Float = 1
    /// Light the part gives off (linear RGB) and how strongly, 0...1.
    public var emissive: SIMD3<Float> = .zero
    public var glow: Float = 0
    public var clearcoat: Float = 0
    public var clearcoatRoughness: Float = 0.1
    public var sheen: Float = 0
    public var isGlass = false
    public var flat = false
    public var doubleSided = false

    public init(color: SIMD3<Float>, roughness: Float, metalness: Float) {
        self.color = color
        self.roughness = roughness
        self.metalness = metalness
    }

    public var isTransparent: Bool { isGlass || opacity < 0.995 }
}

/// The named materials of the figure language (docs/dsl-3d.md §5), tuned for the studio look.
public enum FigureMaterials {
    /// sRGB hex of each preset's own colour, roughness, metalness, then extras.
    private static func preset(_ name: String) -> FigureMaterial {
        func make(_ hex: String, _ rough: Float, _ metal: Float, _ adjust: (inout FigureMaterial) -> Void = { _ in }) -> FigureMaterial {
            var m = FigureMaterial(color: FigureColor.linear(hex: hex)!, roughness: rough, metalness: metal)
            adjust(&m)
            return m
        }
        switch name {
        case "steel": return make("#B9BFC6", 0.3, 1)
        case "chrome": return make("#F2F4F7", 0.07, 1)
        case "aluminum": return make("#D0D3D6", 0.42, 1)
        case "titanium": return make("#9DA5AF", 0.36, 1)
        case "iron": return make("#64686E", 0.68, 0.75)
        case "brass": return make("#D8AE5A", 0.27, 1)
        case "copper": return make("#D1875C", 0.3, 1)
        case "gold": return make("#F1C55E", 0.2, 1)
        case "plastic": return make("#4C83C4", 0.42, 0) { $0.clearcoat = 0.15 }
        case "matte": return make("#8E9298", 0.88, 0) { $0.sheen = 0.2 }
        case "rubber": return make("#2E3135", 0.85, 0) { $0.sheen = 0.35 }
        case "paint": return make("#3E6FB0", 0.38, 0.08) { $0.clearcoat = 0.9; $0.clearcoatRoughness = 0.06 }
        case "ceramic": return make("#F2EDE3", 0.32, 0) { $0.clearcoat = 0.7; $0.clearcoatRoughness = 0.08 }
        case "wood": return make("#B5875A", 0.7, 0) { $0.clearcoat = 0.1 }
        case "paper": return make("#F6F2E8", 0.95, 0) { $0.sheen = 0.1 }
        case "glass": return make("#E6F0FA", 0.04, 0) { $0.opacity = 0.22; $0.isGlass = true; $0.clearcoat = 1 }
        case "water": return make("#4D88AA", 0.03, 0) { $0.opacity = 0.55; $0.isGlass = true }
        case "glow": return make("#FF8A2A", 0.45, 0) { $0.glow = 1 }
        default: return make("#C4C8CE", 0.3, 0) { $0.clearcoat = 0.45; $0.clearcoatRoughness = 0.12 }  // gloss
        }
    }

    /// When a part names no material and no colour.
    public static let fallbackHex = "#C79F62"

    /// Resolve a part mark's `material` object.
    public static func resolve(_ json: JSONValue?) -> FigureMaterial {
        let mat = json?["mat"]?.stringValue
        let colorHex = json?["color"]?.stringValue
        var material: FigureMaterial
        if let mat {
            material = preset(mat)
        } else {
            material = preset("plastic")
            material.color = FigureColor.linear(hex: fallbackHex)!
        }
        if let colorHex, let color = FigureColor.linear(hex: colorHex) { material.color = color }
        if let rough = json?["rough"]?.float { material.roughness = rough }
        if let metal = json?["metal"]?.float { material.metalness = metal }
        if let opacity = json?["opacity"]?.float { material.opacity = opacity }
        if let coat = json?["coat"]?.float { material.clearcoat = coat }
        if let sheen = json?["sheen"]?.float { material.sheen = sheen }
        if let glow = json?["glow"]?.float { material.glow = glow }
        if json?["flat"]?.boolValue == true { material.flat = true }
        if json?["double"]?.boolValue == true { material.doubleSided = true }
        if material.glow > 0 {
            let glowColor = json?["glowColor"]?.stringValue.flatMap(FigureColor.linear(hex:))
            material.emissive = glowColor ?? material.color
        }
        material.roughness = min(1, max(0.03, material.roughness))
        material.metalness = min(1, max(0, material.metalness))
        material.opacity = min(1, max(0.02, material.opacity))
        return material
    }
}
