// Generation fingerprint (T1.6, invariant #5). A stable hash of the *resolved
// environment content only* — names, kinds, and values/account references — with the
// variables in sorted order. It deliberately excludes the source layer and the active
// scene name (design §6.1).
//
// Why excluding source matters: if two different scenes resolve to the exact same
// exported environment, their fingerprints are identical, so a terminal that switches
// between them prints no "changed" notice — because nothing it can observe actually
// changed. That honesty is a mechanism here, not a promise.
//
// SHA-256 (not Swift's per-process-salted Hasher) so the value is reproducible across
// processes and runs — the precmd hook compares fingerprints written by a different
// process.

import Foundation
import CryptoKit

public extension EnvCueCore {
    /// Lowercase hex SHA-256 of the canonical encoding of `env`'s content.
    static func generation(_ env: ResolvedEnv) -> String {
        var canonical = ""
        for v in env.vars { // already sorted by name in ResolvedEnv.init
            let payload: String
            switch v.entry.kind {
            case .plain: payload = v.entry.value ?? ""
            case .secret: payload = v.entry.account ?? "" // account reference, never plaintext
            case .unset: payload = ""
            }
            // \u{0} separates fields, \u{1} terminates records — bytes that cannot
            // appear in a var name, kind, value, or account, so the encoding is
            // unambiguous (no two distinct envs collide on a separator boundary).
            canonical += v.entry.name
            canonical.unicodeScalars.append("\u{0}")
            canonical += v.entry.kind.rawValue
            canonical.unicodeScalars.append("\u{0}")
            canonical += payload
            canonical.unicodeScalars.append("\u{1}")
        }
        let digest = SHA256.hash(data: Data(canonical.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
