// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "OpenClicky",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "OpenClickyKit", targets: ["OpenClickyKit"]),
        .executable(name: "occtl", targets: ["occtl"]),
        .executable(name: "OpenClicky", targets: ["OpenClicky"]),
        .executable(name: "OpenClickyBrowserHost", targets: ["OpenClickyBrowserHost"]),
    ],
    targets: [
        .target(
            name: "OpenClickyKit",
            resources: [
                .copy("Resources/model-catalog.json"),
                // JavaScript run in JavaScriptCore: the drawing engine, its pieces and the 3D geometry kernel.
                .copy("Resources/js"),
                // Metal shader source, compiled at runtime with MTLDevice.makeLibrary(source:).
                .copy("Resources/metal"),
                // The model-facing sections of docs/dsl.md and docs/dsl-3d.md (scripts/sync-prompts.sh), for the brain's prompt.
                .copy("Resources/prompts"),
                // OFL fonts for drawings (Patrick Hand for handwriting, Barlow for card titles), with their licences.
                .copy("Resources/fonts"),
                // Agent skills (the browser skill, vendored vercel-deploy, per-app integration skills) and the starter catalog.
                .copy("Resources/skills"),
            ]
        ),
        .executableTarget(name: "occtl", dependencies: ["OpenClickyKit"]),
        .executableTarget(name: "OpenClicky", dependencies: ["OpenClickyKit"]),
        // Chrome native-messaging host: bridges the OpenClicky browser extension to the app.
        .executableTarget(name: "OpenClickyBrowserHost", dependencies: ["OpenClickyKit"]),
        .executableTarget(name: "UsageLedgerProbe", dependencies: ["OpenClickyKit"], path: "Tests/UsageLedgerProbe"),
        .testTarget(name: "OpenClickyKitTests", dependencies: ["OpenClickyKit", "UsageLedgerProbe"]),
        .testTarget(name: "OpenClickyTests", dependencies: ["OpenClicky"]),
    ]
)
