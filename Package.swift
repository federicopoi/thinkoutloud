// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "LocalDictation",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "LocalDictation", targets: ["LocalDictation"])],
    targets: [
        .target(name: "DictationCore"),
        .target(name: "DictationAudio", dependencies: ["DictationCore"]),
        .executableTarget(name: "LocalDictation", dependencies: ["DictationCore", "DictationAudio"]),
        .testTarget(name: "DictationCoreTests", dependencies: ["DictationCore", "DictationAudio"])
    ]
)
