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
// Encoding (PROPOSAL-002, security gate G3): the canonical form is LENGTH-PREFIXED, not
// separator-delimited. An earlier version framed fields with \u{0}/\u{1} bytes and
// asserted those bytes "cannot appear in a value" — false for an arbitrary plain value.
// A value containing those bytes could make two genuinely different environments encode
// to the same string and collide on one fingerprint → a real env change with an unchanged
// generation → precmd stays silent (a dishonest "nothing changed", breaking invariant #5
// / NFR-2). Length-prefix framing (8-byte big-endian UTF-8 length + bytes, per field) is
// injective for ANY byte content, so distinct environments cannot collide — without
// restricting what a value may contain. (No source self-check can catch a fingerprint
// collision; only the encoding's injectivity can — PROPOSAL-002 §3.)
//
// SHA-256 (not Swift's per-process-salted Hasher) so the value is reproducible across
// processes and runs — the precmd hook compares fingerprints written by a different
// process.

import Foundation
import CryptoKit

public extension EnvCueCore {
    /// Lowercase hex SHA-256 of the length-prefixed canonical encoding of `env`'s content.
    static func generation(_ env: ResolvedEnv) -> String {
        var canonical = Data()

        // Frame one field as: 8-byte big-endian UTF-8 length, then the UTF-8 bytes. The
        // explicit length makes field boundaries unambiguous regardless of the bytes
        // inside, so the encoding is injective and no two distinct envs can collide.
        func appendField(_ string: String) {
            let bytes = Data(string.utf8)
            var length = UInt64(bytes.count).bigEndian
            withUnsafeBytes(of: &length) { canonical.append(contentsOf: $0) }
            canonical.append(bytes)
        }

        for v in env.vars { // already sorted by name in ResolvedEnv.init
            let payload: String
            switch v.entry.kind {
            case .plain: payload = v.entry.value ?? ""
            case .secret: payload = v.entry.account ?? "" // account reference, never plaintext
            case .unset: payload = ""
            }
            appendField(v.entry.name)
            appendField(v.entry.kind.rawValue)
            appendField(payload)
        }

        let digest = SHA256.hash(data: canonical)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
