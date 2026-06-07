// Atomic state writes (T3.2, design §5.1, invariant #6).
//
// The commit point is `generation`: a terminal either reads old gen + old snapshot, or
// new gen + new snapshot — never a new gen pointing at a half-written snapshot. We get
// that by writing each file via tmp → fsync → rename, and writing `generation` LAST.

import Foundation
#if canImport(Darwin)
import Darwin
#endif

public extension EnvCueShell {
    /// Write the full state set atomically (design §5.1):
    ///   1. `snapshot.zsh`  (fsync + rename)
    ///   2. `manifest.json` (fsync + rename)
    ///   3. `generation`    (fsync + rename) — LAST, the commit point.
    ///
    /// `manifest` content is supplied by the caller (derived from ResolvedEnv upstream);
    /// this function only commits it durably — evaluation/serialization stay single-writer
    /// in EnvCueCore (invariant #1).
    ///
    /// `interruptBeforeGenerationCommit` is a test-only seam invoked after the snapshot and
    /// manifest are committed but before `generation` is renamed, used to prove that an
    /// interruption there leaves the old generation in place. It is `nil` in production.
    static func writeState(
        snapshot: String,
        generation: String,
        manifest: Data,
        at paths: EnvCuePaths,
        interruptBeforeGenerationCommit: (() throws -> Void)? = nil
    ) throws {
        try paths.ensureStateDir()

        try atomicWrite(Data(snapshot.utf8), to: paths.snapshotFile)
        try atomicWrite(manifest, to: paths.manifestFile)

        try interruptBeforeGenerationCommit?()

        // Generation written last. A single trailing newline so the shim's
        // `read -r _ENVCUE_GEN < generation` reads the value cleanly.
        try atomicWrite(Data((generation + "\n").utf8), to: paths.generationFile)
    }
}

/// Errors from the atomic write primitive. No secret ever flows through state files
/// (snapshots carry account references only), so these messages are path-only.
enum AtomicWriteError: Error, CustomStringConvertible {
    case renameFailed(to: String, code: Int32)
    case dirSyncFailed(dir: String, code: Int32)

    var description: String {
        switch self {
        case let .renameFailed(to, code):
            return "envcue: could not commit '\(to)' (rename failed, errno \(code))"
        case let .dirSyncFailed(dir, code):
            return "envcue: could not persist directory '\(dir)' (fsync failed, errno \(code))"
        }
    }
}

/// Write `data` to `url` durably and atomically: write a sibling `<name>.tmp`, fsync it,
/// then `rename(2)` it onto `url`. The rename is atomic on the same filesystem, so a
/// concurrent reader sees either the old file or the fully-written new one — never a
/// partial. Permissions default to 0600; callers editing user files (e.g. `.zshrc`) pass
/// the file's existing mode to avoid surprising permission changes.
func atomicWrite(_ data: Data, to url: URL, permissions: Int = 0o600) throws {
    let dir = url.deletingLastPathComponent()
    let tmp = dir.appendingPathComponent(url.lastPathComponent + ".tmp")
    let fm = FileManager.default

    fm.createFile(atPath: tmp.path, contents: nil, attributes: [.posixPermissions: permissions])
    let handle = try FileHandle(forWritingTo: tmp)
    do {
        try handle.write(contentsOf: data)
        try handle.synchronize() // fsync: durably on disk before we expose it via rename
        try handle.close()
    } catch {
        try? handle.close()
        try? fm.removeItem(at: tmp)
        throw error
    }

    if rename(tmp.path, url.path) != 0 {
        let code = errno
        try? fm.removeItem(at: tmp)
        throw AtomicWriteError.renameFailed(to: url.path, code: code)
    }

    // Persist the rename itself. rename(2) makes the new name visible atomically, but the
    // directory entry is not durable until the directory is fsync'd. Without this, a power
    // loss could leave the new `generation` rename persisted while the new `snapshot` rename
    // is not — breaking the commit-point ordering across a crash (NFR-5). Because each
    // atomicWrite fsyncs the directory before returning, the snapshot's rename is durable
    // before the generation rename is even issued by writeState.
    try fsyncDirectory(dir)
}

/// fsync the directory so a just-completed `rename(2)` is durably persisted, not merely
/// visible. (macOS `fsync` flushes to the drive cache, not the platter; F_FULLFSYNC would
/// add platter durability — a documented, acceptable residual for v1.)
private func fsyncDirectory(_ dir: URL) throws {
    let fd = open(dir.path, O_RDONLY)
    guard fd >= 0 else {
        throw AtomicWriteError.dirSyncFailed(dir: dir.path, code: errno)
    }
    defer { close(fd) }
    if fsync(fd) != 0 {
        throw AtomicWriteError.dirSyncFailed(dir: dir.path, code: errno)
    }
}
