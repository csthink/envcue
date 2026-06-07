// EnvCueKeychain — generic-password read/write under service "dev.mars.envcue".
//
// Side effect: Keychain only. This namespace holds the fixed service identifier, the
// account-derivation helper (design §3), and the thin `keychain-get` read path that
// pipes a secret value to stdout. The KeychainStore protocol and its Security-backed
// implementation live alongside in this module (KeychainStore.swift / SystemKeychainStore.swift).
//
// NFR-1: a secret never touches argv, history, or any on-disk file. The account is not
// secret — it may appear in argv — but the value only ever travels through the stdout
// pipe that the snapshot's `$(envcue keychain-get ...)` captures at source time.

import Foundation

public enum EnvCueKeychain {
    /// Keychain service identifier shared across all layers (design §3, locked).
    public static let service = "dev.mars.envcue"

    /// Derive the Keychain account for a variable in a layer (design §3): `"{layer}/{VAR}"`.
    /// `(service, account)` uniquely addresses a secret, so the same variable name can
    /// hold a distinct value per layer.
    public static func account(layer: String, variable: String) -> String {
        "\(layer)/\(variable)"
    }

    /// Read path for `envcue keychain-get --account` (T2.2): fetch the secret via `store`
    /// and write its raw bytes to `handle`. No cache, no disk, no added newline — the
    /// value goes straight to stdout, where the snapshot's `$(...)` captures it (and zsh
    /// strips any trailing newline the value itself may carry).
    ///
    /// `store` does not resolve or evaluate anything; evaluation stays single-writer in
    /// EnvCueCore (invariant #1). Throws `KeychainError.notFound` when the account is absent
    /// so the caller can exit non-zero rather than emit an empty value silently.
    public static func keychainGet(
        account: String,
        store: KeychainStore = SystemKeychainStore(),
        to handle: FileHandle = .standardOutput
    ) throws {
        guard let value = try store.get(account: account) else {
            throw KeychainError.notFound(account: account)
        }
        try handle.write(contentsOf: Data(value.utf8))
    }
}
