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
    // CLI mode. ParsableCommand.main parses, runs, and renders --help / usage / parse
    // errors / ExitCode / run-time errors correctly, exiting with the right status. (The
    // earlier hand-rolled parse-then-run split swallowed ArgumentParser's `helpRequested`
    // into the run-time catch, so `--help` dumped a CommandError instead of the usage text.)
    // Our command/error types print human-readable, secret-free messages by construction.
    EnvCue.main(arguments)
}

struct EnvCue: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "envcue",
        abstract: "Per-terminal environment layer switcher for macOS + zsh.",
        discussion: """
        Switch named environment scenes (base + one mutually-exclusive scene) per terminal.
        Secrets live in the Keychain and travel via a stdout pipe — never argv or history.
        Launching without arguments starts the menu-bar app.
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
