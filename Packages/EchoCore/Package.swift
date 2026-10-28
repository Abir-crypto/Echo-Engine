// swift-tools-version: 6.2
import PackageDescription

let cxxInterop: [SwiftSetting] = [.interoperabilityMode(.Cxx)]

let package = Package(
    name: "EchoCore",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "EchoCore", targets: ["EchoCore"]),
        .library(name: "EchoAudioUnits", targets: ["EchoAudioUnits"]),
    ],
    targets: [
        .target(name: "CEchoDSP"),
        .target(name: "EchoCore", dependencies: ["CEchoDSP"], swiftSettings: cxxInterop),
        .target(name: "EchoAudioUnits", dependencies: ["CEchoDSP"], swiftSettings: cxxInterop),
        .testTarget(name: "EchoCoreTests", dependencies: ["EchoCore", "CEchoDSP"], swiftSettings: cxxInterop),
    ],
    cxxLanguageStandard: .cxx20
)
