// swift-tools-version:6.0
import PackageDescription

// ProbeCore is plain Swift + Foundation so it builds and tests on Linux.
// The SwiftUI app target only exists on macOS.
var products: [Product] = [.library(name: "ProbeCore", targets: ["ProbeCore"])]
var targets: [Target] = [
    .target(name: "ProbeCore"),
    .testTarget(name: "ProbeCoreTests", dependencies: ["ProbeCore"]),
]

#if os(macOS)
products.append(.executable(name: "Probe", targets: ["Probe"]))
targets.append(.executableTarget(name: "Probe", dependencies: ["ProbeCore"]))
#endif

let package = Package(
    name: "MacStorageProbe",
    platforms: [.macOS(.v15)],
    products: products,
    targets: targets,
    swiftLanguageModes: [.v5]
)
