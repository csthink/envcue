// EnvCueKeychain — generic password read/write under service "dev.mars.envcue".
//
// Side effect: Keychain only. Exposes a `KeychainStore` protocol for Core to inject,
// plus the no-cache / no-disk `keychain-get --account` read path that pipes the secret
// value to stdout (NFR-1: secrets never touch argv, history, or any on-disk file).
//
// Real types arrive in T2. This placeholder only establishes the module for T0.

import EnvCueCore

public enum EnvCueKeychain {
    /// Keychain service identifier shared across all layers (design §3).
    public static let service = "dev.mars.envcue"
}
