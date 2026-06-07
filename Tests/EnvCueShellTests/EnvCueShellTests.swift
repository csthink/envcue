import Testing
import Foundation
@testable import EnvCueShell

// MARK: - Test helpers

private func makeTempDir() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("envcue-test-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

// MARK: - Anchors / hook template (T3.4, invariant #4)

@Test func anchorsArePaired() {
    #expect(EnvCueShell.beginAnchor == "# >>> envcue >>>")
    #expect(EnvCueShell.endAnchor == "# <<< envcue <<<")
}

@Test func shimHasNoForkInGenerationCheck() {
    let block = EnvCueShell.shimBlock()
    // Invariant #4: the per-prompt generation check must not fork. No command
    // substitution `$(...)`, no backticks anywhere in the injected block.
    #expect(!block.contains("$("))
    #expect(!block.contains("`"))
    // The cheap builtin read is present, reading from the generation file directly.
    #expect(block.contains("read -r gen < \"$ENVCUE_STATE/generation\""))
    // The precmd source is guarded so a missing snapshot doesn't error every prompt.
    #expect(block.contains("[ -r \"$ENVCUE_STATE/snapshot.zsh\" ] || return"))
    // Block is properly anchored.
    #expect(block.hasPrefix(EnvCueShell.beginAnchor))
    #expect(block.hasSuffix(EnvCueShell.endAnchor))
}

@Test func precmdSurvivesMissingSnapshotWithoutErrorOrAdvancingGeneration() throws {
    let root = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: root) }

    // The shim body sourced standalone; we drive `_envcue_precmd` directly.
    let bodyFile = root.appendingPathComponent("shim_body.zsh")
    try EnvCueShell.shimBody().write(to: bodyFile, atomically: true, encoding: .utf8)

    // Pathological state: a generation exists but snapshot.zsh does NOT (e.g. user deleted it).
    // After the gen changes, precmd must early-return (no fork, no error) and must NOT advance
    // _ENVCUE_GEN — so when the snapshot returns it still gets applied.
    let script = """
    export XDG_CONFIG_HOME='\(root.path)'
    STATE="$XDG_CONFIG_HOME/envcue/state"
    mkdir -p "$STATE"
    printf 'GENOLD\\n' > "$STATE/generation"
    source '\(bodyFile.path)'              # top-level read sets _ENVCUE_GEN=GENOLD
    printf 'GENNEW\\n' > "$STATE/generation"  # gen changed, snapshot still absent
    _envcue_precmd
    print -r -- "gen=$_ENVCUE_GEN"
    """

    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/bin/zsh")
    proc.arguments = ["-c", script]
    let out = Pipe()
    let err = Pipe()
    proc.standardOutput = out
    proc.standardError = err

    try proc.run()
    proc.waitUntilExit()

    let stdout = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    let stderr = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

    // No error spam from a missing snapshot (the guard's `[ -r ]` test is silent).
    #expect(!stderr.lowercased().contains("no such file"))
    // The recorded generation was NOT advanced past GENOLD, so the snapshot still gets
    // applied if it returns. (precmd's own non-zero exit is harmless: zsh preserves $?
    // across precmd hooks, so it never leaks into the user's prompt.)
    #expect(stdout.contains("gen=GENOLD"))
}

// MARK: - Path resolution (T3.1)

@Test func pathsResolveDefaultAndXDG() {
    let home = URL(fileURLWithPath: "/Users/test")

    let def = EnvCuePaths.resolve(environment: [:], home: home)
    #expect(def.configDir.path == "/Users/test/.config/envcue")
    #expect(def.stateDir.path == "/Users/test/.config/envcue/state")
    #expect(def.snapshotFile.lastPathComponent == "snapshot.zsh")
    #expect(def.generationFile.lastPathComponent == "generation")
    #expect(def.manifestFile.lastPathComponent == "manifest.json")

    let xdg = EnvCuePaths.resolve(environment: ["XDG_CONFIG_HOME": "/tmp/xdg"], home: home)
    #expect(xdg.configDir.path == "/tmp/xdg/envcue")

    // Empty XDG falls back to ~/.config.
    let empty = EnvCuePaths.resolve(environment: ["XDG_CONFIG_HOME": ""], home: home)
    #expect(empty.configDir.path == "/Users/test/.config/envcue")
}

// MARK: - Atomic write & commit-point ordering (T3.2, invariant #6)

@Test func writeStateProducesConsistentFilesAndNoTmpLeftovers() throws {
    let root = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = EnvCuePaths(configDir: root.appendingPathComponent("envcue"))

    try EnvCueShell.writeState(
        snapshot: "export A=1\n",
        generation: "GEN1",
        manifest: Data(#"{"A":"base"}"#.utf8),
        at: paths
    )

    #expect(try String(contentsOf: paths.snapshotFile, encoding: .utf8) == "export A=1\n")
    #expect(try String(contentsOf: paths.generationFile, encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines) == "GEN1")
    #expect(try String(contentsOf: paths.manifestFile, encoding: .utf8) == #"{"A":"base"}"#)

    // No `.tmp` files left behind after a successful commit.
    let leftovers = try FileManager.default
        .contentsOfDirectory(atPath: paths.stateDir.path)
        .filter { $0.hasSuffix(".tmp") }
    #expect(leftovers.isEmpty)
}

@Test func generationIsCommittedLastSoNoHalfWriteIsVisible() throws {
    let root = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = EnvCuePaths(configDir: root.appendingPathComponent("envcue"))

    // Clean baseline: generation = GEN1.
    try EnvCueShell.writeState(snapshot: "export A=1\n", generation: "GEN1",
                               manifest: Data("{}".utf8), at: paths)

    // Second apply interrupted right before the generation commit point.
    struct Boom: Error {}
    #expect(throws: Boom.self) {
        try EnvCueShell.writeState(snapshot: "export A=2\n", generation: "GEN2",
                                   manifest: Data("{}".utf8), at: paths) {
            throw Boom()
        }
    }

    // The snapshot was already swapped to the new content, but generation still reads GEN1.
    // A live terminal holding GEN1 reads GEN1 from the file → early-returns → never sources
    // a snapshot under a generation that doesn't match it. Commit point held (invariant #6).
    #expect(try String(contentsOf: paths.generationFile, encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines) == "GEN1")
    #expect(try String(contentsOf: paths.snapshotFile, encoding: .utf8) == "export A=2\n")
}

// MARK: - Shim idempotency & cleanliness (T3.3, FR-6)

@Test func installIsIdempotentAndPreservesUserContent() throws {
    let root = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    let rc = root.appendingPathComponent(".zshrc")
    try "alias ll='ls -la'\nexport FOO=bar\n".write(to: rc, atomically: true, encoding: .utf8)

    for _ in 0..<3 { try EnvCueShell.install(into: rc) }

    let after = try String(contentsOf: rc, encoding: .utf8)
    // Exactly one block.
    #expect(after.components(separatedBy: EnvCueShell.beginAnchor).count - 1 == 1)
    #expect(after.components(separatedBy: EnvCueShell.endAnchor).count - 1 == 1)
    // User content untouched.
    #expect(after.contains("alias ll='ls -la'"))
    #expect(after.contains("export FOO=bar"))
    #expect(after.contains("_envcue_precmd"))
}

@Test func installIntoFreshFileCreatesBlock() throws {
    let root = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    let rc = root.appendingPathComponent(".zshrc") // does not exist yet

    try EnvCueShell.install(into: rc)

    let content = try String(contentsOf: rc, encoding: .utf8)
    #expect(content.contains(EnvCueShell.beginAnchor))
    #expect(content.contains(EnvCueShell.endAnchor))
    #expect(content.contains("autoload -Uz add-zsh-hook"))
}

@Test func uninstallRemovesBlockCleanlyAndRestoresFile() throws {
    let root = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    let rc = root.appendingPathComponent(".zshrc")
    let original = "alias ll='ls -la'\nexport FOO=bar\n"
    try original.write(to: rc, atomically: true, encoding: .utf8)

    try EnvCueShell.install(into: rc)
    try EnvCueShell.uninstall(from: rc)

    let cleaned = try String(contentsOf: rc, encoding: .utf8)
    #expect(!cleaned.contains("envcue"))
    #expect(!cleaned.contains(EnvCueShell.beginAnchor))
    // Original content (and its layout) restored.
    #expect(cleaned == original)
}

// MARK: - End-to-end: a real zsh sources a secret-bearing snapshot (T3 DoD #4)

@Test func zshSourcesSnapshotAndExportsSecretViaStubbedKeychainGet() throws {
    let root = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = EnvCuePaths(configDir: root.appendingPathComponent("envcue"))

    // A faithfully-shaped serialized secret line: the value is NOT in the file, only the
    // `$(envcue keychain-get ...)` reference (invariant #2).
    let snapshot = """
    # AUTO-GENERATED by envcue — do not edit. generation=testgen
    export OPENAI_API_KEY="$(envcue keychain-get --account 'work/OPENAI_API_KEY')"
    """ + "\n"
    try EnvCueShell.writeState(snapshot: snapshot, generation: "testgen",
                               manifest: Data("{}".utf8), at: paths)

    // The on-disk snapshot must contain the reference, never a plaintext secret.
    let onDisk = try String(contentsOf: paths.snapshotFile, encoding: .utf8)
    #expect(onDisk.contains("$(envcue keychain-get --account 'work/OPENAI_API_KEY')"))
    #expect(!onDisk.contains("STUBBED_SECRET_VALUE"))

    // Stub `envcue` on PATH so the snapshot's $(...) resolves without a real Keychain.
    let bin = root.appendingPathComponent("bin", isDirectory: true)
    try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    let stub = bin.appendingPathComponent("envcue")
    let secret = "STUBBED_SECRET_VALUE"
    try "#!/bin/zsh\nif [[ \"$1\" == \"keychain-get\" ]]; then printf '%s' '\(secret)'; fi\n"
        .write(to: stub, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)

    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/bin/zsh")
    proc.arguments = ["-c", "source '\(paths.snapshotFile.path)'; printf '%s' \"$OPENAI_API_KEY\""]
    var env = ProcessInfo.processInfo.environment
    env["PATH"] = bin.path + ":" + (env["PATH"] ?? "")
    proc.environment = env
    let out = Pipe()
    proc.standardOutput = out

    try proc.run()
    proc.waitUntilExit()

    let produced = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
    #expect(produced == secret)
    #expect(proc.terminationStatus == 0)
}
