// CLIContext — the composition seam for the CLI (T4).
//
// Every subcommand is deliberately thin: it parses arguments and calls into this
// context, which wires EnvCueCore (single writer for model/eval/diff/serialize),
// EnvCueKeychain (secret storage), and EnvCueShell (atomic state + shim). No evaluation
// or serialization is re-implemented here (invariant #1) — the CLI only loads inputs,
// asks Core to resolve them, and hands the products to Shell to commit.
//
// Security floor (invariant #2): the only place a plaintext secret VALUE is touched is
// `readSecretFromStdin()` (value read from stdin, never argv) → `store.set`. It never
// reaches a TOML file, the snapshot, the manifest, argv, or any printed line — layer
// files and the manifest carry only the account reference and Core's masked
// `displayValue`.

import Foundation
import EnvCueCore
import EnvCueKeychain
import EnvCueShell

/// Shared wiring for the subcommands. `store` is injectable so future tests can swap a
/// fake; production uses the real Security-backed Keychain.
struct CLIContext {
    let paths: EnvCuePaths
    let store: KeychainStore

    init(paths: EnvCuePaths = .resolve(), store: KeychainStore = SystemKeychainStore()) {
        self.paths = paths
        self.store = store
    }

    // MARK: - Loading inputs

    func loadConfig() throws -> GlobalConfig {
        guard let toml = try? String(contentsOf: paths.configFile, encoding: .utf8) else {
            return GlobalConfig() // no config yet → base-only, keychain backend
        }
        return try EnvCueCore.loadConfig(toml: toml)
    }

    func loadBase() throws -> Layer {
        guard let toml = try? String(contentsOf: paths.baseFile, encoding: .utf8) else {
            return Layer(name: "base", entries: []) // no base.toml yet → empty base
        }
        return try EnvCueCore.loadLayer(name: "base", toml: toml)
    }

    /// File backing a layer: `base` → `base.toml`, any other name → `scenes/<name>.toml`.
    func layerFile(_ layer: String) -> URL {
        layer == "base" ? paths.baseFile : paths.scenesDir.appendingPathComponent("\(layer).toml")
    }

    /// Load a layer for editing (`secret set/rm`). Absent file → empty layer to create.
    func loadLayerForEdit(_ layer: String) throws -> Layer {
        guard let toml = try? String(contentsOf: layerFile(layer), encoding: .utf8) else {
            return Layer(name: layer, entries: [])
        }
        return try EnvCueCore.loadLayer(name: layer, toml: toml)
    }

    /// Resolve a scene layer that the user is switching/diffing *to*. A missing file is an
    /// error here — a typo'd scene name must fail loudly before anything is written.
    func loadSceneStrict(_ name: String?) throws -> Layer? {
        guard let name else { return nil }
        try EnvCueCore.validateLayerName(name) // argv → filename component: reject traversal
        guard let toml = try? String(contentsOf: layerFile(name), encoding: .utf8) else {
            throw CLIError.sceneNotFound(name)
        }
        return try EnvCueCore.loadLayer(name: name, toml: toml)
    }

    /// Resolve the *current* active scene for diff/base computation. A missing file falls
    /// back to base-only (the active scene file may have been deleted out from under us;
    /// that should not crash a switch to a different scene).
    func loadSceneOptional(_ name: String?) throws -> Layer? {
        guard let name else { return nil }
        guard let toml = try? String(contentsOf: layerFile(name), encoding: .utf8) else {
            return nil
        }
        return try EnvCueCore.loadLayer(name: name, toml: toml)
    }

    /// Scene names available under `scenes/` (file stems, sorted).
    func sceneNames() -> [String] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: paths.scenesDir, includingPropertiesForKeys: nil)) ?? []
        return urls
            .filter { $0.pathExtension == "toml" }
            .map { $0.deletingPathExtension().lastPathComponent }
            .sorted()
    }

    // MARK: - The apply path (single writer; design §10)

    /// A planned switch: the change preview plus the resolved target environment to commit.
    /// Produced by `planSwitch` (read-only), consumed by `commitSwitch` (the only writer).
    struct SwitchPlan {
        let target: String?
        let changes: [Change]
        let next: ResolvedEnv
    }

    /// Read-only half of the apply path (design §10): evaluate current→target and diff. No
    /// file is written here. Shared verbatim by the CLI `scene` command and the GUI's inline
    /// diff preview, so evaluation lives in exactly one place (invariant #1 / NFR-6). A bad
    /// scene name fails here (loadSceneStrict) before anything downstream runs.
    func planSwitch(target: String?) throws -> SwitchPlan {
        let config = try loadConfig()
        let base = try loadBase()
        let current = EnvCueCore.evaluate(base: base, scene: try loadSceneOptional(config.active))
        let next = EnvCueCore.evaluate(base: base, scene: try loadSceneStrict(target))
        return SwitchPlan(target: target, changes: EnvCueCore.diff(current: current, next: next), next: next)
    }

    /// Writing half of the apply path: commit state first (snapshot + manifest, generation
    /// last — design §10), then move the active pointer. Generation excludes the scene name,
    /// so a switch between two scenes that resolve to the same env leaves generation
    /// unchanged: existing terminals stay quiet (honest), the menu bar still updates from
    /// config.active. The single writer for both CLI and GUI switches.
    func commitSwitch(_ plan: SwitchPlan) throws {
        let config = try loadConfig()
        try commitState(env: plan.next, activeScene: plan.target)
        try writeActive(plan.target, config: config)
    }

    /// Switch the active scene: plan (eval → diff) → confirm → commit. `target == nil` means
    /// base-only (`--none`). Nothing is written if the user declines the confirmation.
    func applyScene(target: String?, yes: Bool) throws {
        let plan = try planSwitch(target: target)
        let label = target ?? "base"

        printDiff(plan.changes, targetLabel: label)

        if !plan.changes.isEmpty && !yes {
            guard confirm() else {
                print("envcue: aborted. No changes written.")
                return
            }
        }

        try commitSwitch(plan)

        if plan.changes.isEmpty {
            print("envcue: '\(label)' is now active (environment unchanged).")
        } else {
            print("envcue: switched to '\(label)'.")
        }
    }

    /// Serialize + fingerprint + manifest via Core, then commit atomically via Shell.
    func commitState(env: ResolvedEnv, activeScene: String?) throws {
        // Read what the previous snapshot exported BEFORE we overwrite the manifest, so the
        // new snapshot can unset variables the old scene left behind (PROPOSAL-004). This is
        // the only input that ties cleanup to the actually-sourced prior state.
        let previousNames = previousManifestNames()
        let snapshot = EnvCueCore.serialize(env, activeScene: activeScene, previousNames: previousNames)
        let generation = EnvCueCore.generation(env)
        let manifest = try buildManifest(env: env, active: activeScene, generation: generation)
        try EnvCueShell.writeState(
            snapshot: snapshot,
            generation: generation,
            manifest: manifest,
            at: paths
        )
    }

    /// Variable names recorded in the last committed `manifest.json` (the env an
    /// already-open shell most recently sourced). Empty when there is no prior manifest or
    /// it cannot be read — the first apply has nothing to clean up. Only the `vars` keys
    /// are needed; values there are already masked (invariant #2).
    private func previousManifestNames() -> Set<String> {
        guard let data = try? Data(contentsOf: paths.manifestFile),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let vars = obj["vars"] as? [String: Any] else {
            return []
        }
        return Set(vars.keys)
    }

    // MARK: - Writing config & layer files (plaintext, user-owned)

    func ensureConfigDir() throws {
        try FileManager.default.createDirectory(
            at: paths.configDir, withIntermediateDirectories: true)
    }

    /// Update only `active`, preserving `secret_backend`. Foundation atomic write (temp +
    /// rename); config.toml is user-owned plaintext, not generated state.
    func writeActive(_ active: String?, config: GlobalConfig) throws {
        var updated = config
        updated.active = active
        try ensureConfigDir()
        try Data(EnvCueCore.saveConfig(updated).utf8).write(to: paths.configFile, options: .atomic)
    }

    /// Persist a layer model back to its TOML file (creating `scenes/` if needed).
    func writeLayer(_ layer: Layer) throws {
        try ensureConfigDir()
        let url = layerFile(layer.name)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(EnvCueCore.saveLayer(layer).utf8).write(to: url, options: .atomic)
    }

    // MARK: - Secret input (the one plaintext touchpoint; invariant #2)

    /// Read a secret value from stdin so it never appears in argv or shell history. A
    /// single trailing newline (and CR) — what `echo` / here-strings append — is stripped;
    /// interior newlines are preserved for multi-line secrets.
    func readSecretFromStdin() throws -> String {
        let data = (try? FileHandle.standardInput.readToEnd()) ?? Data()
        guard var value = String(data: data, encoding: .utf8) else {
            throw CLIError.secretNotUTF8
        }
        if value.hasSuffix("\n") { value.removeLast() }
        if value.hasSuffix("\r") { value.removeLast() }
        guard !value.isEmpty else { throw CLIError.emptySecretInput }
        return value
    }

    // MARK: - Manifest (generated state; masked, secret-free)

    /// Build `manifest.json`: a name → {source, masked value} listing for status/inspection.
    /// Values come from Core's `displayValue`, so secrets are `secret(<account>)` — never
    /// plaintext (invariant #2). `.sortedKeys` keeps it deterministic.
    private func buildManifest(env: ResolvedEnv, active: String?, generation: String) throws -> Data {
        struct Manifest: Encodable {
            let active: String?
            let generation: String
            let vars: [String: Record]
            struct Record: Encodable {
                let source: String
                let value: String
            }
        }
        var vars: [String: Manifest.Record] = [:]
        for v in env.vars {
            vars[v.name] = .init(source: v.source.label, value: v.displayValue)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(Manifest(active: active, generation: generation, vars: vars))
    }

    // MARK: - Presentation

    /// Print a diff preview. Secrets show their account reference (masked), never plaintext.
    func printDiff(_ changes: [Change], targetLabel: String) {
        guard !changes.isEmpty else {
            print("envcue: no environment changes for '\(targetLabel)'.")
            return
        }
        print("envcue: changes for '\(targetLabel)':")
        for c in changes {
            switch c.kind {
            case .added:
                print("  + \(c.name) = \(c.newDisplay ?? "") [\(c.source.label)]")
            case .removed:
                print("  - \(c.name) (was \(c.oldDisplay ?? "")) [\(c.source.label)]")
            case .changed:
                print("  ~ \(c.name): \(c.oldDisplay ?? "") → \(c.newDisplay ?? "") [\(c.source.label)]")
            }
        }
    }

    /// Interactive yes/no confirmation (default No). Used by `scene` without `--yes`.
    func confirm() -> Bool {
        FileHandle.standardOutput.write(Data("Apply these changes? [y/N] ".utf8))
        guard let line = readLine() else { return false }
        let answer = line.trimmingCharacters(in: .whitespaces).lowercased()
        return answer == "y" || answer == "yes"
    }
}

// MARK: - Layer model edits (value construction, not evaluation)

extension Layer {
    /// Return a copy with `entry` inserted or replacing any same-named entry.
    func upserting(_ entry: VarEntry) -> Layer {
        Layer(name: name, entries: entries.filter { $0.name != entry.name } + [entry])
    }

    /// Return a copy with the entry named `variable` removed (if present).
    func removing(_ variable: String) -> Layer {
        Layer(name: name, entries: entries.filter { $0.name != variable })
    }
}

// MARK: - Errors

/// CLI-level errors. Human-readable and secret-free (project rule): they carry only
/// scene/layer/variable names, never a value.
enum CLIError: Error, CustomStringConvertible {
    case sceneNotFound(String)
    case emptySecretInput
    case secretNotUTF8

    var description: String {
        switch self {
        case let .sceneNotFound(name):
            return "envcue: no such scene '\(name)' (expected a file under scenes/)"
        case .emptySecretInput:
            return "envcue: no secret value on stdin (pipe or type the value, e.g. `printf %s \"$KEY\" | envcue secret set ...`)"
        case .secretNotUTF8:
            return "envcue: secret value on stdin is not valid UTF-8"
        }
    }
}

/// Write a line to stderr (used by the internal `keychain-get` failure path).
func printErr(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}
