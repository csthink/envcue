// KeychainStore — the injection seam for secret storage (T2.1).
//
// The protocol lives here (not in EnvCueCore) on purpose: Core is the single writer for
// model/evaluation/diff/serialization and never reads a secret VALUE — it only ever
// emits the account reference `$(envcue keychain-get --account '...')` (invariant #2).
// So the real consumer of this seam is the CLI (`secret set/rm`, `keychain-get`), and
// keeping the protocol + its Security-backed implementation together in this module
// keeps Core untouched. Tests inject a fake conforming type.

import Foundation

/// Read/write/delete for generic-password secrets under `EnvCueKeychain.service`.
///
/// `get` returns `nil` for an absent account (not an error) so callers can distinguish
/// "no such secret" from a real Keychain failure. No conformer ever caches plaintext or
/// writes it to disk — the value lives only in the Keychain and, transiently, in the
/// shell that captures `keychain-get`'s stdout.
public protocol KeychainStore: Sendable {
    /// Insert or overwrite the secret at `account`. The value is never logged or echoed.
    func set(account: String, value: String) throws
    /// Fetch the secret at `account`, or `nil` if there is no such entry.
    func get(account: String) throws -> String?
    /// Remove the secret at `account`. Idempotent: absent is treated as success.
    func delete(account: String) throws
}

/// Keychain failures surfaced to the user.
///
/// Invariant #2 (security floor): **no case carries the secret value**, so a Display
/// string can never leak a key. Cases hold only the non-secret account reference or a
/// numeric `OSStatus`. `Equatable` is for test assertions.
public enum KeychainError: Error, Equatable, CustomStringConvertible {
    /// The account had no Keychain entry (used by the `keychain-get` read path).
    case notFound(account: String)
    /// The stored item was not decodable as UTF-8 text.
    case unexpectedData(account: String)
    /// Any other Security-framework status that isn't success or not-found.
    case unhandled(status: OSStatus)

    public var description: String {
        switch self {
        case let .notFound(account):
            return "envcue: no keychain entry for account '\(account)'"
        case let .unexpectedData(account):
            return "envcue: keychain entry for account '\(account)' is not valid UTF-8"
        case let .unhandled(status):
            return "envcue: keychain error (OSStatus \(status))"
        }
    }
}
