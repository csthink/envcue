// GUI state model (T5). The menu/diff views render off this single observable model.
//
// `SceneSource` is the seam onto the apply path. There are two real implementations — the
// live one delegating to CLIContext (single writer; invariant #1 / NFR-6) and the demo one
// feeding the visual preview harness — so the protocol is warranted, not premature.
//
// Secrets never reach the GUI as plaintext (invariant #2): change rows carry only Core's
// masked `displayValue` (`secret(<account>)`), produced by `Core.diff`.

import Foundation
import Observation
import EnvCueCore

/// One selectable scene in the menu (plus the synthetic "base only" entry).
struct SceneOption: Identifiable, Hashable {
    /// `nil` name is the base-only entry (`scene --none`).
    let name: String?
    var id: String { name ?? "\u{0}base-only" }
    var title: String { name ?? "Base only" }
}

/// What the GUI needs from the apply path. `plan` is read-only; `apply` is the sole writer.
@MainActor
protocol SceneSource {
    func scenes() -> [SceneOption]
    func activeScene() -> String?
    /// Evaluate current→target and return the change preview (no write). Reuses `Core.diff`.
    func plan(target: String?) throws -> [Change]
    /// Apply the switch to `target` (atomic commit + active pointer). Re-plans against fresh
    /// state at commit time so the write reflects the latest layer files.
    func apply(target: String?) throws
}

@Observable
@MainActor
final class AppModel {
    private let source: SceneSource
    private let watcher: FileWatcher?

    /// Available scenes, base-only first, then scene files sorted (mirrors CLI listing).
    private(set) var options: [SceneOption]
    /// Active scene name; `nil` == base only. Drives the menu bar label (FR-1), read from
    /// config.toml `active` — decoupled from generation (invariant #5).
    private(set) var active: String?
    /// A pending switch awaiting confirmation: the target plus its diff preview. `nil` when
    /// the menu is showing the scene list. Set by `beginSwitch`, cleared by `confirm`/`cancel`.
    var pending: PendingSwitch?
    /// Last error surfaced to the user (e.g. a missing scene file). Secret-free by construction.
    var errorMessage: String?

    struct PendingSwitch: Identifiable {
        let target: SceneOption
        let changes: [Change]
        var id: String { target.id }
    }

    init(source: SceneSource, watching configFile: URL? = nil) {
        self.source = source
        self.options = source.scenes()
        self.active = source.activeScene()
        // FR-1: track external switches (e.g. `envcue scene` from a terminal) so the menu
        // bar label stays in sync without the user reopening the menu.
        if let configFile {
            let w = FileWatcher(url: configFile)
            self.watcher = w
            w.onChange = { [weak self] in self?.refresh() }
        } else {
            self.watcher = nil
        }
    }

    /// Re-read scenes + active from the source (on menu open, after apply, or on file change).
    func refresh() {
        options = source.scenes()
        active = source.activeScene()
    }

    /// Menu bar label text: the active scene name, or "base" when none (FR-1).
    var labelText: String { active ?? "base" }

    /// True for the option that is currently active (checkmarked in the menu).
    func isActive(_ option: SceneOption) -> Bool { option.name == active }

    /// User picked a scene → compute the change preview and show the inline diff. Nothing is
    /// written here; apply happens only on `confirm`.
    func beginSwitch(to option: SceneOption) {
        guard !isActive(option) else { return } // switching to current is a no-op
        do {
            let changes = try source.plan(target: option.name)
            pending = PendingSwitch(target: option, changes: changes)
        } catch {
            errorMessage = String(describing: error)
        }
    }

    /// Confirm the pending switch: apply via the shared writer, update active, return to list.
    func confirm() {
        guard let pending else { return }
        do {
            try source.apply(target: pending.target.name)
            active = pending.target.name
            self.pending = nil
            refresh()
        } catch {
            errorMessage = String(describing: error)
        }
    }

    /// Dismiss the preview without writing anything (cancel never touches disk).
    func cancel() { pending = nil }
}

// MARK: - Live source (delegates to the single-writer apply path)

/// Production `SceneSource`: every read/write goes through `CLIContext` — the same apply
/// path the CLI uses (NFR-6). No evaluation/diff is reimplemented here.
@MainActor
final class LiveSceneSource: SceneSource {
    private let ctx = CLIContext()

    var configFile: URL { ctx.paths.configFile }

    func scenes() -> [SceneOption] {
        [SceneOption(name: nil)] + ctx.sceneNames().map { SceneOption(name: $0) }
    }

    func activeScene() -> String? {
        (try? ctx.loadConfig())?.active
    }

    func plan(target: String?) throws -> [Change] {
        try ctx.planSwitch(target: target).changes
    }

    func apply(target: String?) throws {
        try ctx.commitSwitch(ctx.planSwitch(target: target))
    }
}

// MARK: - Demo source (visual preview harness only; no disk access)

/// Fake `SceneSource` for the ENVCUE_GUI_PREVIEW harness. PATH-free change set (invariant #3:
/// the preview must never show a PATH edit); secrets shown only as account references.
@MainActor
final class DemoSceneSource: SceneSource {
    func scenes() -> [SceneOption] {
        [SceneOption(name: nil), SceneOption(name: "personal"), SceneOption(name: "work")]
    }

    func activeScene() -> String? { "personal" }

    func plan(target: String?) throws -> [Change] {
        let src = Source.scene(target ?? "base")
        return [
            Change(name: "AWS_PROFILE", kind: .added, source: src,
                   oldDisplay: nil, newDisplay: "work-sso"),
            Change(name: "API_BASE_URL", kind: .changed, source: src,
                   oldDisplay: "https://api.dev.internal", newDisplay: "https://api.prod.internal"),
            Change(name: "OPENAI_API_KEY", kind: .changed, source: src,
                   oldDisplay: "secret(personal/OPENAI_API_KEY)",
                   newDisplay: "secret(\(target ?? "base")/OPENAI_API_KEY)"),
            Change(name: "DEBUG", kind: .removed, source: .base,
                   oldDisplay: "1", newDisplay: nil),
        ]
    }

    func apply(target: String?) throws { /* preview harness: no-op, never writes */ }
}

// MARK: - Config file watcher (FR-1)

/// Watches a single file for writes/renames and fires `onChange` on the main actor. Used to
/// keep the menu bar label in sync when the active scene changes from outside the GUI. The
/// CLI commits via temp+rename, so we re-arm on `.delete`/`.rename` as well as `.write`.
@MainActor
final class FileWatcher {
    var onChange: (() -> Void)?
    private let url: URL
    private var source: DispatchSourceFileSystemObject?

    init(url: URL) {
        self.url = url
        arm()
    }

    deinit { source?.cancel() } // cancel handler closes the captured fd

    private func arm() {
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { return } // file may not exist yet; nothing to watch
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
        src.setEventHandler { [weak self] in
            guard let self else { return }
            self.onChange?()
            self.rearm() // atomic writers replace the inode; re-open to follow the new file
        }
        src.setCancelHandler { close(fd) } // each source owns and closes its own fd
        self.source = src
        src.resume()
    }

    private func rearm() {
        source?.cancel() // closes the old fd via its cancel handler
        source = nil
        arm()
    }
}
