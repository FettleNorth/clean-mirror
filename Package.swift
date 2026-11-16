// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "CleanMirror",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "cleanmirror", targets: ["cleanmirror"]),
        .executable(name: "CleanMirrorApp", targets: ["CleanMirrorApp"]),
    ],
    targets: [
        // Thin C wrapper around Blackmagic's C++ DeckLink API (SDK 16.0 headers in sdk/).
        .target(
            name: "DeckLinkShim",
            path: "Sources/DeckLinkShim",
            cxxSettings: [.headerSearchPath("sdk")],
            linkerSettings: [
                .linkedFramework("CoreFoundation"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("Accelerate"),
            ]
        ),
        // Creates the 1920x1080 virtual screen (CoreGraphics' undocumented CGVirtualDisplay).
        .target(
            name: "VirtualDisplay",
            path: "Sources/VirtualDisplay",
            cSettings: [.unsafeFlags(["-fobjc-arc"])],
            linkerSettings: [
                .linkedFramework("Foundation"),
                .linkedFramework("CoreGraphics"),
            ]
        ),
        // The mirror engine shared by the command-line tool and the menu bar app.
        .target(
            name: "MirrorKit",
            dependencies: ["DeckLinkShim", "VirtualDisplay"],
            path: "Sources/MirrorKit",
            linkerSettings: [
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("CoreVideo"),
            ]
        ),
        .executableTarget(
            name: "cleanmirror",
            dependencies: ["MirrorKit"],
            path: "Sources/cleanmirror",
            linkerSettings: [.linkedFramework("ImageIO")]
        ),
        .executableTarget(
            name: "CleanMirrorApp",
            dependencies: ["MirrorKit"],
            path: "Sources/CleanMirrorApp",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ServiceManagement"),
            ]
        ),
    ],
    swiftLanguageModes: [.v5],
    cxxLanguageStandard: .cxx17
)
