// Diff (T1.4). Computes the change set between two resolved environments for the
// pre-switch preview (design §7). Secrets are compared by account reference only —
// never decrypted (invariant #2). Output is sorted by name for determinism.

public extension EnvCueCore {
    /// Variables present in `next` but not `current` are `added`; those gone are
    /// `removed`; those whose effective content differs are `changed`.
    ///
    /// "Content" means kind + value (plain) / account (secret). The source *layer* is
    /// carried for display but does not by itself make a `changed`: if a var's exported
    /// value is identical, the environment did not actually change. This keeps diff
    /// aligned with the generation fingerprint (invariant #5).
    static func diff(current: ResolvedEnv, next: ResolvedEnv) -> [Change] {
        let cur = current.byName
        let nxt = next.byName
        let names = Set(cur.keys).union(nxt.keys).sorted()

        var changes: [Change] = []
        for name in names {
            switch (cur[name], nxt[name]) {
            case let (.none, .some(n)):
                changes.append(Change(name: name, kind: .added, source: n.source,
                                      oldDisplay: nil, newDisplay: n.displayValue))
            case let (.some(c), .none):
                changes.append(Change(name: name, kind: .removed, source: c.source,
                                      oldDisplay: c.displayValue, newDisplay: nil))
            case let (.some(c), .some(n)):
                if !sameContent(c.entry, n.entry) {
                    changes.append(Change(name: name, kind: .changed, source: n.source,
                                          oldDisplay: c.displayValue, newDisplay: n.displayValue))
                }
            case (.none, .none):
                break
            }
        }
        return changes
    }

    /// Effective-content equality: same kind and same value/account. For secrets this
    /// compares the account reference only — no decryption.
    private static func sameContent(_ a: VarEntry, _ b: VarEntry) -> Bool {
        a.kind == b.kind && a.value == b.value && a.account == b.account
    }
}
