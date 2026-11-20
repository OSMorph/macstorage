// swift-tools-version:6.0
import PackageDescription

// StorageCore is plain Swift + Foundation so it builds and tests on Linux.
// StorageMac (scanning, cleanup) and the MacStorage app only exist on macOS.
var products: [Product] = [.library(name: "StorageCore", targets: ["StorageCore"])]
var targets: [Target] = [
    .target(name: "StorageCore"),
    .testTarget(name: "StorageCoreTests", dependencies: ["StorageCore"], resources: [.copy("Fixtures")]),
]

#if os(macOS)
products += [
    .library(name: "StorageMac", targets: ["StorageMac"]),
    .executable(name: "MacStorage", targets: ["MacStorage"]),
]
targets += [
    .target(name: "StorageMac", dependencies: ["StorageCore"]),
    .executableTarget(name: "MacStorage", dependencies: ["StorageCore", "StorageMac"]),
    .testTarget(name: "StorageMacTests", dependencies: ["StorageMac"]),
]
#endif

let package = Package(
    name: "MacStorage",
    platforms: [.macOS(.v15)],
    products: products,
    targets: targets
)
