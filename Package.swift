// swift-tools-version: 6.0
import PackageDescription

// Layering mirrors the original binary:
//   RVL    — Revolution SDK replacements (ES/WAD, ARC/U8, CX/LZ) — platform-free
//   GX     — GX GPU state model, texture decoding, TEV → Metal Shading Language generator
//   NW4R   — NintendoWare for Revolution resource formats + runtime (g3d, later lyt/ut/snd)
//   Forecast — the decompiled channel itself (d_scene, SimpleGlobe, d_weather_*) + Metal backend
//   ForecastMac — macOS shell (window, mouse → pointer). The iPhone app (portrait, touch) lives in iOS/.
let package = Package(
    name: "ForecastChannel",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .executable(name: "ForecastMac", targets: ["ForecastMac"]),
        .executable(name: "fcdump", targets: ["fcdump"]),
        .executable(name: "fcsound", targets: ["fcsound"]),
        .executable(name: "fcdata", targets: ["fcdata"]),
        .executable(name: "fcupscale", targets: ["fcupscale"]),
        .library(name: "Forecast", targets: ["Forecast"]),
    ],
    targets: [
        .target(name: "RVL"),
        .target(name: "GX", dependencies: ["RVL"]),
        .target(name: "NW4R", dependencies: ["RVL", "GX"]),
        .target(name: "Forecast", dependencies: ["RVL", "GX", "NW4R"]),
        .executableTarget(name: "ForecastMac", dependencies: ["Forecast"]),
        .executableTarget(name: "fcdump", dependencies: ["Forecast"]),
        .executableTarget(name: "fcsound", dependencies: ["Forecast"]),   // sound track dev tool
        .executableTarget(name: "fcdata", dependencies: ["Forecast"]),    // forecast data track dev tool
        .executableTarget(name: "fcupscale", dependencies: ["Forecast", "NW4R", "RVL"]),   // AI ×4 texture upscaling (iPhone)
    ],
    swiftLanguageModes: [.v5]
)
