// swift-tools-version:6.1
import PackageDescription

// EnvCue v1 — per-terminal environment layer switcher (macOS Tahoe 26+, zsh only).
// Layering (design §1.1): EnvCueCore is the single writer for model/evaluation/diff/
// serialization; EnvCueKeychain and EnvCueShell carry the side effects; the `envcue`
// executable is the double-mode entry (argv → CLI, no argv → GUI placeholder until T5).
let package = Package(
    name: "envcue",
    platforms: [
        .macOS("26.0"),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
        // TOML load/save for layer files and config.toml (T1.2). toml++-backed parser
        // chosen over a hand-rolled one to avoid subtle quoting/escaping corruption.
        .package(url: "https://github.com/LebJe/TOMLKit.git", from: "0.6.0"),
    ],
    targets: [
        // MARK: - Libraries (pure-logic first, side effects later)
        .target(
            name: "EnvCueCore",
            dependencies: [
                .product(name: "TOMLKit", package: "TOMLKit"),
            ]
        ),
        .target(
            name: "EnvCueKeychain",
            dependencies: ["EnvCueCore"]
        ),
        .target(
            name: "EnvCueShell",
            dependencies: ["EnvCueCore"]
        ),

        // MARK: - Executable (double-mode entry)
        .executableTarget(
            name: "envcue",
            dependencies: [
                "EnvCueCore",
                "EnvCueKeychain",
                "EnvCueShell",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),

        // MARK: - Test targets (one per library)
        .testTarget(
            name: "EnvCueCoreTests",
            dependencies: ["EnvCueCore"]
        ),
        .testTarget(
            name: "EnvCueKeychainTests",
            dependencies: ["EnvCueKeychain"]
        ),
        .testTarget(
            name: "EnvCueShellTests",
            dependencies: ["EnvCueShell"]
        ),
    ]
)
