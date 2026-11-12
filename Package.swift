// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MagnusVector",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "MagnusVector", targets: ["MagnusVector"])],
    targets: [
        .executableTarget(name: "MagnusVector"),
        .testTarget(name: "MagnusVectorTests", dependencies: ["MagnusVector"], resources: [.copy("Fixtures")])
    ],
    swiftLanguageModes: [.v5]
)
