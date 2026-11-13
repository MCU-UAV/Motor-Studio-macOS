// swift-tools-version: 6.0
import PackageDescription

var products: [Product] = [.library(name: "MotorCore", targets: ["MotorCore"])]
var targets: [Target] = [
    .target(name: "CSerial"),
    .target(name: "MotorCore", dependencies: ["CSerial"]),
    .testTarget(name: "MotorCoreTests", dependencies: ["MotorCore"], resources: [.copy("Fixtures")])
]
#if os(macOS)
products.append(.executable(name: "MotorStudio", targets: ["MotorStudio"]))
targets.append(.executableTarget(name: "MotorStudio", dependencies: ["MotorCore"]))
#endif

let package = Package(
    name: "MotorStudio",
    platforms: [.macOS(.v14)],
    products: products,
    targets: targets,
    swiftLanguageModes: [.v5]
)
