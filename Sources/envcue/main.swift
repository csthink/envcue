// envcue — double-mode entry (design §1.1).
//
//   has subcommand argv  → CLI mode (EnvCueCLI command tree; subcommands land in T4)
//   no argv (launched as the .app) → GUI mode (MenuBarExtra; arrives in T5)
//
// T0 ships only the skeleton: the CLI root prints usage via swift-argument-parser, and
// the GUI branch prints a placeholder and exits (no AppKit/SwiftUI dependency yet).

import ArgumentParser

let arguments = Array(CommandLine.arguments.dropFirst())

if arguments.isEmpty {
    // GUI mode placeholder — the real MenuBarExtra agent arrives in T5.
    print("envcue: GUI mode placeholder (MenuBarExtra arrives in T5). Run `envcue --help` for CLI usage.")
} else {
    // CLI mode — ArgumentParser handles parsing, `--help`, and exit codes.
    EnvCue.main(arguments)
}

struct EnvCue: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "envcue",
        abstract: "Per-terminal environment layer switcher for macOS + zsh.",
        discussion: """
        Skeleton entry (T0). Subcommands (scene / eval / diff / status / snapshot /
        secret / install / uninstall) are assembled in T4. Launching without arguments
        starts GUI mode (placeholder until T5).
        """
    )
}
