// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "BarTap",
    platforms: [.macOS(.v13)],
    targets: [
        // Pure logic (no AppKit state), unit-tested by BarTapTests.
        .target(name: "BarTapCore", path: "Sources/BarTapCore"),
        .executableTarget(
            name: "BarTap",
            dependencies: ["BarTapCore"],
            path: "Sources/BarTap",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Carbon"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("IOKit"),
                .linkedFramework("Network"),
                .linkedFramework("CoreWLAN"),
                .linkedFramework("SystemConfiguration"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("IOBluetooth"),
                .linkedFramework("CoreBluetooth"),
            ]
        ),
        // CommandLineTools ship without XCTest, so tests are a plain executable.
        .executableTarget(name: "BarTapTests", dependencies: ["BarTapCore"], path: "Sources/BarTapTests"),
        // Reports what each menu bar is drawing; used by scripts/live_test.py.
        .executableTarget(name: "BarTapProbe", dependencies: ["BarTapCore"], path: "Sources/BarTapProbe"),
    ],
    swiftLanguageVersions: [.v5]
)
