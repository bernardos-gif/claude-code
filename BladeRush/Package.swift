// swift-tools-version:5.9
// BLADE RUSH — Swift Package manifest.
//
// Targets:
//   BladeCore   — all platform-independent game code: math, combat, AI, animation,
//                 procedural meshes/textures/audio, game modes, UI layout, save system.
//                 Builds on macOS and Linux so the simulation can be unit-tested headless.
//   BladeRush   — the macOS application: AppKit window, Metal renderer, AVAudioEngine
//                 output, GameController/keyboard input. macOS only.
//   BladeSim    — headless command-line tool: runs bot-vs-boss simulations, self tests,
//                 data validation and CPU preview renders (useful for bug reports).
import PackageDescription

var targets: [Target] = [
    .target(
        name: "BladeCore",
        path: "Sources/BladeCore"
    ),
    .executableTarget(
        name: "BladeSim",
        dependencies: ["BladeCore"],
        path: "Sources/BladeSim"
    ),
    .testTarget(
        name: "BladeCoreTests",
        dependencies: ["BladeCore"],
        path: "Tests/BladeCoreTests"
    ),
]

#if os(macOS)
targets.append(
    .executableTarget(
        name: "BladeRush",
        dependencies: ["BladeCore"],
        path: "Sources/BladeRush",
        // Shaders are compiled at runtime from source (see ShaderLibrary.swift),
        // the build script copies them into the .app bundle.
        exclude: ["Shaders"],
        linkerSettings: [
            .linkedFramework("Metal"),
            .linkedFramework("MetalKit"),
            .linkedFramework("MetalFX"),
            .linkedFramework("AppKit"),
            .linkedFramework("GameController"),
            .linkedFramework("AVFoundation"),
        ]
    )
)
#endif

let package = Package(
    name: "BladeRush",
    platforms: [.macOS(.v14)],
    targets: targets
)
