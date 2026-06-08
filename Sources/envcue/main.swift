// envcue — double-mode entry (design §1.1).
//
//   has subcommand argv  → CLI mode (EnvCue command tree, assembled in T4)
//   no argv (launched as the .app) → GUI mode (MenuBarExtra; arrives in T5)
//
// The CLI subcommands are thin wrappers over EnvCueCore/Keychain/Shell (see Commands.swift
// + CLIContext.swift). The GUI branch still prints a placeholder until T5.

import Foundation
import ArgumentParser

let arguments = Array(CommandLine.arguments.dropFirst())

if arguments.isEmpty {
    // GUI mode — launch the MenuBarExtra agent (T5). Never returns.
    runGUI()
} else {
    // CLI mode. Parse with ArgumentParser (so bad args / --help render usage nicely), then
    // run — surfacing run-time errors as a single readable line on stderr rather than a
    // backtrace (project rule: user-facing errors are human-readable; no key ever appears
    // because our error types are secret-free by construction).
    do {
        var command = try EnvCue.parseAsRoot(arguments)
        do {
            try command.run()
        } catch let exit as ExitCode {
            EnvCue.exit(withError: exit) // honor explicit exit codes (message already printed)
        } catch {
            // String(describing:) prefers an error's CustomStringConvertible description —
            // all our error types provide a readable, secret-free one.
            printErr(String(describing: error))
            EnvCue.exit(withError: ExitCode.failure)
        }
    } catch {
        // Parse / validation / help request — ArgumentParser renders usage + help.
        EnvCue.exit(withError: error)
    }
}

struct EnvCue: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "envcue",
        abstract: "Per-terminal environment layer switcher for macOS + zsh.",
        discussion: """
        Switch named environment scenes (base + one mutually-exclusive scene) per terminal.
        Secrets live in the Keychain and travel via a stdout pipe — never argv or history.
        Launching without arguments starts GUI mode (placeholder until T5).
        """,
        subcommands: [
            SceneCommand.self,
            EvalCommand.self,
            DiffCommand.self,
            SnapshotCommand.self,
            StatusCommand.self,
            SecretCommand.self,
            KeychainGetCommand.self,
            InstallCommand.self,
            UninstallCommand.self,
        ]
    )
}
