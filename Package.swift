// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "Codefluence", platforms: [.iOS(.v16)], products: [.library(name: "Codefluence", targets: ["Codefluence"])], targets: [.target(name: "Codefluence", resources: [.process("Resources")]), .testTarget(name: "CodefluenceTests", dependencies: ["Codefluence"])])
