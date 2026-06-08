// EnvCueCore — the single writer (NFR-6, invariant #1).
//
// Owns the data model, TOML load/save, the pure `evaluate(base, scene?)` function,
// diff, snapshot text serialization, and the generation fingerprint. No side effects:
// Keychain access is injected through a protocol (T2) so this module stays
// unit-testable end to end. Real values never live in this module — secrets are only
// ever account references (invariant #2).

/// Namespace for the core pure-logic surface. All entry points hang off this enum
/// as static functions so both CLI and GUI call one implementation (invariant #1).
public enum EnvCueCore {}

/// User-facing errors raised while loading config/layer files.
///
/// `description` is a human-readable message (project rule: errors are readable, not
/// backtraces) and — by construction — **never contains a secret**: these cases only
/// carry variable names, layer names, and `kind`/backend strings, never values.
public enum EnvCueCoreError: Error, Equatable, CustomStringConvertible {
    /// A layer/config file could not be parsed as TOML.
    case malformedFile(name: String)
    /// A `[vars.X]` table is missing a field its `kind` requires.
    case missingField(name: String, field: String)
    /// A `kind`/`secret_backend` value outside the known set.
    case unknownValue(context: String, value: String)
    /// A variable name that is not a legal POSIX env name (PROPOSAL-001 / G3 shell-safety).
    case illegalVarName(name: String, layer: String)
    /// A Keychain account reference containing characters unsafe in the sourced snapshot.
    case illegalAccount(layer: String, variable: String)
    /// A layer name unsafe as a filename component / account prefix.
    case illegalLayerName(layer: String)
    /// `PATH` appeared in a layer — envcue performs zero PATH operations (NFR-4).
    case pathManagedExternally(layer: String)

    public var description: String {
        switch self {
        case let .malformedFile(name):
            return "envcue: could not parse '\(name)' as TOML"
        case let .missingField(name, field):
            return "envcue: variable '\(name)' is missing required field '\(field)'"
        case let .unknownValue(context, value):
            return "envcue: unknown value '\(value)' in \(context)"
        case let .illegalVarName(name, layer):
            return "envcue: layer '\(layer)' variable name '\(name)' is illegal — allowed: letters, digits, underscore; must not start with a digit. Fix the layer file."
        case let .illegalAccount(layer, variable):
            return "envcue: layer '\(layer)' variable '\(variable)' has an illegal Keychain account reference (only letters, digits, and '_ / . -' are allowed). Fix the layer file."
        case let .illegalLayerName(layer):
            return "envcue: layer name '\(layer)' is illegal — allowed: letters, digits, underscore, hyphen."
        case let .pathManagedExternally(layer):
            return "envcue: 'PATH' is delegated to mise/direnv and is never managed by envcue (zero-PATH policy) — remove it from layer '\(layer)'."
        }
    }
}
