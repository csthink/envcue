// EnvCueCore — the single writer (NFR-6).
//
// Owns the data model, TOML load/save, the pure `evaluate(base, scene?)` function,
// diff, and snapshot text serialization. No side effects: Keychain access is injected
// through a protocol so this module stays unit-testable end to end.
//
// Real types arrive in T1 (model → evaluate → diff → serialize → generation).
// This placeholder only establishes the module so T0's skeleton builds.

public enum EnvCueCore {
    /// Module marker used by the T0 skeleton; replaced by real types in T1.
    public static let module = "EnvCueCore"
}
