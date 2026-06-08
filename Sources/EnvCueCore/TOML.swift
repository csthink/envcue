// TOML load/save (T1.2). Layer files and config.toml ⇄ model types (design §2.3).
//
// We use TOMLKit (toml++ under the hood) rather than a hand-rolled parser: getting
// TOML quoting/escaping subtly wrong could corrupt a user's config, which is at odds
// with the determinism red line. Layer `secret` entries store only an account
// reference — never plaintext (invariant #2).

import TOMLKit

public extension EnvCueCore {
    // MARK: - Layer

    /// Parse a layer file. `name` is supplied by the caller (file stem), not the file.
    static func loadLayer(name: String, toml: String) throws -> Layer {
        let root: TOMLTable
        do {
            root = try TOMLTable(string: toml)
        } catch {
            throw EnvCueCoreError.malformedFile(name: name)
        }

        var entries: [VarEntry] = []
        if let vars = root["vars"]?.table {
            for key in vars.keys.sorted() {
                guard let vt = vars[key]?.table else {
                    throw EnvCueCoreError.malformedFile(name: name)
                }
                // Shell-safety gate (PROPOSAL-001 / G3): reject any name that would inject
                // into the sourced snapshot — checked before the value/account so a bad
                // (possibly shared) file is rejected regardless of kind.
                try validateVarName(key, layer: name)
                guard let kindStr = vt["kind"]?.string else {
                    throw EnvCueCoreError.missingField(name: key, field: "kind")
                }
                switch kindStr {
                case VarKind.plain.rawValue:
                    guard let value = vt["value"]?.string else {
                        throw EnvCueCoreError.missingField(name: key, field: "value")
                    }
                    entries.append(.plain(key, value))
                case VarKind.secret.rawValue:
                    guard let account = vt["account"]?.string else {
                        throw EnvCueCoreError.missingField(name: key, field: "account")
                    }
                    try validateAccount(account, layer: name, variable: key)
                    entries.append(.secret(key, account: account))
                case VarKind.unset.rawValue:
                    entries.append(.unset(key))
                default:
                    throw EnvCueCoreError.unknownValue(context: "vars.\(key).kind", value: kindStr)
                }
            }
        }
        return Layer(name: name, entries: entries)
    }

    /// Serialize a layer to TOML. Entries are written sorted by name so output is
    /// deterministic and round-trips without field loss.
    static func saveLayer(_ layer: Layer) -> String {
        let root = TOMLTable()
        let vars = TOMLTable()
        for entry in layer.entries.sorted(by: { $0.name < $1.name }) {
            let vt = TOMLTable()
            vt["kind"] = TOMLValue(stringLiteral: entry.kind.rawValue)
            switch entry.kind {
            case .plain:
                vt["value"] = TOMLValue(stringLiteral: entry.value ?? "")
            case .secret:
                vt["account"] = TOMLValue(stringLiteral: entry.account ?? "")
            case .unset:
                break
            }
            vars[entry.name] = vt
        }
        root["vars"] = vars
        return root.convert()
    }

    // MARK: - Config

    /// Parse `config.toml`. Missing/empty `active` means base-only; `secret_backend`
    /// defaults to keychain.
    static func loadConfig(toml: String) throws -> GlobalConfig {
        let root: TOMLTable
        do {
            root = try TOMLTable(string: toml)
        } catch {
            throw EnvCueCoreError.malformedFile(name: "config.toml")
        }

        let rawActive = root["active"]?.string
        let active = (rawActive?.isEmpty == false) ? rawActive : nil

        let backendStr = root["secret_backend"]?.string ?? SecretBackend.keychain.rawValue
        guard let backend = SecretBackend(rawValue: backendStr) else {
            throw EnvCueCoreError.unknownValue(context: "secret_backend", value: backendStr)
        }
        return GlobalConfig(active: active, secretBackend: backend)
    }

    /// Serialize global config. An empty/nil active scene is omitted (base-only).
    static func saveConfig(_ config: GlobalConfig) -> String {
        let root = TOMLTable()
        if let active = config.active, !active.isEmpty {
            root["active"] = TOMLValue(stringLiteral: active)
        }
        root["secret_backend"] = TOMLValue(stringLiteral: config.secretBackend.rawValue)
        return root.convert()
    }
}
