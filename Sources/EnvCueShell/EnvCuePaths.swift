// EnvCuePaths — config/state directory layout (T3.1, design §2).
//
// Resolves the XDG config root (`$XDG_CONFIG_HOME/envcue`, falling back to
// `~/.config/envcue`) and the generated `state/` subtree. Construction is injectable
// (`init(configDir:)`) so tests run against a temp directory and never touch the real
// HOME. `resolve(environment:home:)` is the production entry point.

import Foundation

public struct EnvCuePaths: Sendable {
    /// `…/envcue` — the per-user config root (plaintext, hand-editable, shareable).
    public let configDir: URL

    public init(configDir: URL) {
        self.configDir = configDir
    }

    /// Resolve from the process environment. `XDG_CONFIG_HOME` wins when set and non-empty,
    /// else `~/.config` (design §2.1).
    public static func resolve(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> EnvCuePaths {
        let configBase: URL
        if let xdg = environment["XDG_CONFIG_HOME"], !xdg.isEmpty {
            configBase = URL(fileURLWithPath: xdg, isDirectory: true)
        } else {
            configBase = home.appendingPathComponent(".config", isDirectory: true)
        }
        return EnvCuePaths(configDir: configBase.appendingPathComponent("envcue", isDirectory: true))
    }

    // MARK: - Config files (plaintext, user-owned)

    public var configFile: URL { configDir.appendingPathComponent("config.toml") }
    public var baseFile: URL { configDir.appendingPathComponent("base.toml") }
    public var scenesDir: URL { configDir.appendingPathComponent("scenes", isDirectory: true) }

    // MARK: - State files (generated, do not hand-edit — design §2.2)

    public var stateDir: URL { configDir.appendingPathComponent("state", isDirectory: true) }
    public var snapshotFile: URL { stateDir.appendingPathComponent("snapshot.zsh") }
    public var generationFile: URL { stateDir.appendingPathComponent("generation") }
    public var manifestFile: URL { stateDir.appendingPathComponent("manifest.json") }

    /// Create `state/` (and parents) if absent. 0700 since it is the user's own state.
    public func ensureStateDir() throws {
        try FileManager.default.createDirectory(
            at: stateDir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }
}
