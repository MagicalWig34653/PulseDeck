// swift-tools-version: 6.2
import PackageDescription

// PulseDeckKit holds everything that does not depend on SwiftUI/AppKit:
// snapshot models, the monitoring engine, sampling policy, history buffers and
// counter math. Keeping it UI-free enforces SPEC §4 (telemetry separated from
// presentation) and lets the core be unit tested with `swift test`.
let package = Package(
    name: "PulseDeckKit",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "PulseDeckCore", targets: ["PulseDeckCore"]),
        .library(name: "PulseDeckTelemetry", targets: ["PulseDeckTelemetry"]),
    ],
    targets: [
        .target(name: "PulseDeckCore"),
        // Darwin collectors (Mach, sysctl, libproc, IOKit, Metal, SystemConfiguration, CoreWLAN). Sources are compiled on
        // macOS only; all calculations they rely on live in PulseDeckCore.
        .target(
            name: "PulseDeckTelemetry",
            dependencies: ["PulseDeckCore"],
            linkerSettings: [
                .linkedFramework("CoreWLAN", .when(platforms: [.macOS])),
                .linkedFramework("IOKit", .when(platforms: [.macOS])),
                .linkedFramework("Metal", .when(platforms: [.macOS])),
                .linkedFramework("SystemConfiguration", .when(platforms: [.macOS])),
            ]
        ),
        .testTarget(name: "PulseDeckCoreTests", dependencies: ["PulseDeckCore"]),
        .testTarget(name: "PulseDeckTelemetryTests", dependencies: ["PulseDeckTelemetry", "PulseDeckCore"]),
    ],
    swiftLanguageModes: [.v6]
)
