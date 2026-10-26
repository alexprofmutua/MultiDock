// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MultiDockCore",
    platforms: [.macOS(.v14)],
    products: [.library(name: "MultiDockCore", targets: ["MultiDockCore"])],
    targets: [
        .target(name: "MultiDockCore", path: "MultiDock",
                exclude: ["App", "Managers", "Windows", "Views", "Services", "Persistence/README.md"],
                sources: ["Models", "Persistence/DockStore.swift"]),
        .testTarget(name: "MultiDockCoreTests", dependencies: ["MultiDockCore"], path: "Tests")
    ]
)
