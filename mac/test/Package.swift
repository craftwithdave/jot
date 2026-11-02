// swift-tools-version:5.9
// Linux test harness for Sources/JotCore.swift (crypto, logic, sync), using swift-crypto. Run: ./run.sh
import PackageDescription
let package = Package(
  name: "JotTest",
  dependencies: [.package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0")],
  targets: [.executableTarget(name: "JotTest", dependencies: [.product(name: "Crypto", package: "swift-crypto")])]
)
