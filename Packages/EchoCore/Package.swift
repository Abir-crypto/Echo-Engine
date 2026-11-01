// swift-tools-version: 6.2
import PackageDescription

let cxxInterop: [SwiftSetting] = [.interoperabilityMode(.Cxx)]

let package = Package(
    name: "EchoCore",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "EchoCore", targets: ["EchoCore"]),
        .library(name: "EchoAudioUnits", targets: ["EchoAudioUnits"]),
        .library(name: "EchoCoreFakes", targets: ["EchoCoreFakes"]),
    ],
    targets: [
        .target(name: "CEchoDSP"),
        .target(name: "EchoCore", dependencies: ["CEchoDSP"], swiftSettings: cxxInterop),
        .target(name: "EchoAudioUnits", dependencies: ["CEchoDSP"], swiftSettings: cxxInterop),
        .target(name: "EchoCoreFakes", dependencies: ["EchoCore"], swiftSettings: cxxInterop),
        // Test-only: replaces `operator new` in the test binary to prove kernels don't allocate. Not a product.
        .target(name: "CEchoDSPTestSupport", path: "Tests/CEchoDSPTestSupport"),
        .testTarget(
            name: "EchoCoreTests",
            dependencies: ["EchoCore", "EchoCoreFakes", "CEchoDSP", "CEchoDSPTestSupport"],
            resources: [.copy("Resources")],
            swiftSettings: cxxInterop
        ),
    ],
    cxxLanguageStandard: .cxx20
)
