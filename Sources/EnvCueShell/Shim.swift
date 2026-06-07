// Shim install/uninstall + precmd hook template (T3.3 / T3.4, design §6, FR-6).
//
// The shim is injected into the user's ~/.zshrc between the paired anchors
// `# >>> envcue >>>` / `# <<< envcue <<<`. Install is idempotent: an existing block is
// replaced in place, so running it N times leaves exactly one block. Uninstall removes
// the block (and the single blank separator we added) without disturbing the rest.
//
// Invariant #4 (no fork per prompt): the precmd generation check is a zsh builtin
// `read -r gen < file` — never `$(cat ...)`, no command substitution, no backticks. The
// snapshot is only `source`d when the generation actually changed.

import Foundation

public extension EnvCueShell {
    /// The hook body that lives between the anchors (design §6). Pure zsh: parameter
    /// expansion only, no command substitution — so each prompt costs one builtin read.
    static func shimBody() -> String {
        """
        export ENVCUE_STATE="${XDG_CONFIG_HOME:-$HOME/.config}/envcue/state"
        [ -r "$ENVCUE_STATE/snapshot.zsh" ] && source "$ENVCUE_STATE/snapshot.zsh"
        [ -r "$ENVCUE_STATE/generation" ] && read -r _ENVCUE_GEN < "$ENVCUE_STATE/generation"

        _envcue_precmd() {
          local gen
          [ -r "$ENVCUE_STATE/generation" ] || return
          read -r gen < "$ENVCUE_STATE/generation"
          [ "$gen" = "$_ENVCUE_GEN" ] && return
          [ -r "$ENVCUE_STATE/snapshot.zsh" ] || return
          source "$ENVCUE_STATE/snapshot.zsh"
          _ENVCUE_GEN="$gen"
          [ -n "$_ENVCUE_NOTICE" ] && print -P "$_ENVCUE_NOTICE"
        }
        autoload -Uz add-zsh-hook && add-zsh-hook precmd _envcue_precmd
        """
    }

    /// The full anchored block, ready to write into `.zshrc`.
    static func shimBlock() -> String {
        "\(beginAnchor)\n\(shimBody())\n\(endAnchor)"
    }

    /// Idempotently install/update the shim in `url`. Replaces an existing block in place,
    /// or appends one (with a blank separator) when none is present. Creates `url` if absent.
    static func install(into url: URL) throws {
        let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let updated = replacingOrAppendingShim(in: existing)
        try atomicWrite(Data(updated.utf8), to: url, permissions: existingPermissions(of: url, default: 0o644))
    }

    /// Remove the shim block (and the blank separator preceding it) from `url`. No-op if
    /// the file or block is absent. The rest of the file is left byte-for-byte intact.
    static func uninstall(from url: URL) throws {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return }
        guard let stripped = removingShim(from: content) else { return }
        try atomicWrite(Data(stripped.utf8), to: url, permissions: existingPermissions(of: url, default: 0o644))
    }

    // MARK: - Pure text transforms (testable without touching the filesystem)

    /// Replace the first…last anchored block with a fresh one, or append if none exists.
    /// Collapsing first-begin … last-end inclusive also heals any accidental duplicate.
    static func replacingOrAppendingShim(in content: String) -> String {
        let lines = content.components(separatedBy: "\n")
        if let begin = lines.firstIndex(where: isBeginAnchor),
           let end = lines.lastIndex(where: isEndAnchor),
           begin <= end {
            var result = Array(lines[..<begin])
            result.append(contentsOf: shimBlock().components(separatedBy: "\n"))
            if end + 1 < lines.count {
                result.append(contentsOf: lines[(end + 1)...])
            }
            return result.joined(separator: "\n")
        }

        // Append: keep a clean blank-line separation from any existing content.
        var result = content
        if !result.isEmpty {
            if !result.hasSuffix("\n") { result += "\n" }
            result += "\n"
        }
        return result + shimBlock() + "\n"
    }

    /// Remove the anchored block, returning `nil` when there is nothing to remove (so the
    /// caller can skip the write). Drops a single blank separator line just before the block.
    static func removingShim(from content: String) -> String? {
        let lines = content.components(separatedBy: "\n")
        guard let begin = lines.firstIndex(where: isBeginAnchor),
              let end = lines.lastIndex(where: isEndAnchor),
              begin <= end else {
            return nil
        }
        var head = Array(lines[..<begin])
        if let last = head.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
            head.removeLast()
        }
        var result = head
        if end + 1 < lines.count {
            result.append(contentsOf: lines[(end + 1)...])
        }
        return result.joined(separator: "\n")
    }

    // MARK: - Helpers

    private static func isBeginAnchor(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespaces).hasPrefix(beginAnchor)
    }

    private static func isEndAnchor(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespaces).hasPrefix(endAnchor)
    }

    private static func existingPermissions(of url: URL, default fallback: Int) -> Int {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let mode = attrs[.posixPermissions] as? NSNumber else {
            return fallback
        }
        return mode.intValue
    }
}
