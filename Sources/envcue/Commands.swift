// CLI subcommands (T4, design §9). Each is thin: parse args, delegate to CLIContext.
// No evaluation/serialization lives here (invariant #1); no plaintext secret is ever
// printed or written to a file (invariant #2).

import Foundation
import ArgumentParser
import EnvCueCore
import EnvCueKeychain
import EnvCueShell

// MARK: - scene

struct SceneCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "scene",
        abstract: "Switch the active scene (eval → diff → confirm → atomic apply). Omit the name to list scenes."
    )

    @Argument(help: "Scene to activate.") var name: String?
    @Flag(name: .long, help: "Clear the active scene (base only).") var none = false
    @Flag(name: [.short, .long], help: "Skip the confirmation prompt.") var yes = false

    func run() throws {
        let ctx = CLIContext()
        if none {
            try ctx.applyScene(target: nil, yes: yes)
            return
        }
        guard let name else {
            try listScenes(ctx)
            return
        }
        try ctx.applyScene(target: name, yes: yes)
    }

    private func listScenes(_ ctx: CLIContext) throws {
        let config = try ctx.loadConfig()
        let names = ctx.sceneNames()
        if names.isEmpty {
            print("envcue: no scenes defined. Add files under \(ctx.paths.scenesDir.path)")
        }
        for n in names {
            print("\(n == config.active ? "* " : "  ")\(n)")
        }
        if config.active == nil {
            print("  (base only — no active scene)")
        }
    }
}

// MARK: - eval

struct EvalCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "eval",
        abstract: "Print the resolved environment (secrets masked). Debugging aid."
    )

    @Option(name: .long, help: "Evaluate this scene instead of the active one.") var scene: String?

    func run() throws {
        let ctx = CLIContext()
        let config = try ctx.loadConfig()
        let base = try ctx.loadBase()
        let layer = try ctx.loadSceneStrict(scene ?? config.active)
        let env = EnvCueCore.evaluate(base: base, scene: layer)
        for v in env.vars {
            print("\(v.name)=\(v.displayValue)") // displayValue masks secrets; plain values are not secret
        }
    }
}

// MARK: - diff

struct DiffCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "diff",
        abstract: "Preview the change set from the current environment to a scene."
    )

    @Argument(help: "Scene to compare against the current environment.") var name: String

    func run() throws {
        let ctx = CLIContext()
        let config = try ctx.loadConfig()
        let base = try ctx.loadBase()
        let current = EnvCueCore.evaluate(base: base, scene: try ctx.loadSceneOptional(config.active))
        let next = EnvCueCore.evaluate(base: base, scene: try ctx.loadSceneStrict(name))
        ctx.printDiff(EnvCueCore.diff(current: current, next: next), targetLabel: name)
    }
}

// MARK: - snapshot

struct SnapshotCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "snapshot",
        abstract: "Regenerate the snapshot for the current active scene (idempotent)."
    )

    func run() throws {
        let ctx = CLIContext()
        let config = try ctx.loadConfig()
        let base = try ctx.loadBase()
        let env = EnvCueCore.evaluate(base: base, scene: try ctx.loadSceneOptional(config.active))
        // Same env → same generation: a re-run is a true no-op for live terminals.
        try ctx.commitState(env: env, activeScene: config.active)
        print("envcue: snapshot regenerated at \(ctx.paths.snapshotFile.path)")
    }
}

// MARK: - status

struct StatusCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Show the active scene, generation, and snapshot path."
    )

    func run() throws {
        let ctx = CLIContext()
        let config = try ctx.loadConfig()
        let gen = (try? String(contentsOf: ctx.paths.generationFile, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        print("scene:      \(config.active ?? "base (none)")")
        print("backend:    \(config.secretBackend.rawValue)")
        print("generation: \(gen?.isEmpty == false ? gen! : "(none)")")
        print("snapshot:   \(ctx.paths.snapshotFile.path)")
    }
}

// MARK: - secret set / rm

struct SecretCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "secret",
        abstract: "Manage secrets: store in Keychain and register the reference in a layer.",
        subcommands: [Set.self, Rm.self]
    )

    struct Set: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "set",
            abstract: "Read a secret value from stdin → Keychain, and register its reference in the layer."
        )

        @Argument(help: "Layer to attach the secret to (`base` or a scene name).") var layer: String
        @Argument(help: "Variable name, e.g. OPENAI_API_KEY.") var variable: String

        func run() throws {
            let ctx = CLIContext()
            // Shell-safety gate (PROPOSAL-001 / G3): validate argv-supplied names BEFORE any
            // Keychain write or file write, so an injection like `secret set work 'FOO;rm -rf ~'`
            // is rejected and never reaches a layer file or the sourced snapshot.
            try EnvCueCore.validateLayerName(layer)
            try EnvCueCore.validateVarName(variable, layer: layer)
            let account = EnvCueKeychain.account(layer: layer, variable: variable)
            try EnvCueCore.validateAccount(account, layer: layer, variable: variable)

            let value = try ctx.readSecretFromStdin() // stdin, never argv (invariant #2)

            // Keychain first: if the layer-file write fails, the value is at least present
            // and the command can be re-run; the reverse would leave a dangling reference.
            try ctx.store.set(account: account, value: value)

            let model = try ctx.loadLayerForEdit(layer).upserting(.secret(variable, account: account))
            try ctx.writeLayer(model)

            print("envcue: stored secret '\(variable)' in layer '\(layer)' (account \(account)).")
        }
    }

    struct Rm: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "rm",
            abstract: "Remove a secret from the Keychain and drop its reference from the layer."
        )

        @Argument(help: "Layer the secret belongs to.") var layer: String
        @Argument(help: "Variable name to remove.") var variable: String

        func run() throws {
            let ctx = CLIContext()
            try EnvCueCore.validateLayerName(layer)   // path-safety before touching files
            try EnvCueCore.validateVarName(variable, layer: layer)
            let account = EnvCueKeychain.account(layer: layer, variable: variable)
            try ctx.store.delete(account: account) // idempotent

            let model = try ctx.loadLayerForEdit(layer)
            let existed = model.entries.contains { $0.name == variable }
            try ctx.writeLayer(model.removing(variable))

            print(existed
                ? "envcue: removed secret '\(variable)' from layer '\(layer)'."
                : "envcue: no reference '\(variable)' in layer '\(layer)'; Keychain entry cleared if present.")
        }
    }
}

// MARK: - keychain-get (internal)

struct KeychainGetCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "keychain-get",
        abstract: "Internal: read a secret to stdout (called by snapshot.zsh).",
        shouldDisplay: false
    )

    @Option(name: .long, help: "Keychain account ({layer}/{VAR}).") var account: String

    func run() throws {
        let ctx = CLIContext()
        do {
            // Value goes straight to stdout where the snapshot's $(...) captures it.
            try EnvCueKeychain.keychainGet(account: account, store: ctx.store)
        } catch let error as KeychainError {
            printErr("\(error)")
            throw ExitCode.failure
        }
    }
}

// MARK: - install / uninstall

struct InstallCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "install",
        abstract: "Inject the envcue precmd shim into ~/.zshrc (idempotent)."
    )

    func run() throws {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".zshrc")
        try EnvCueShell.install(into: url)
        print("envcue: shim installed in \(url.path). Open a new terminal or run: source ~/.zshrc")
    }
}

struct UninstallCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "uninstall",
        abstract: "Remove the envcue shim block from ~/.zshrc."
    )

    func run() throws {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".zshrc")
        try EnvCueShell.uninstall(from: url)
        print("envcue: shim removed from \(url.path).")
    }
}
