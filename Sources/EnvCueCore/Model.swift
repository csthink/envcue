// Data model (T1.1). Mirrors spec §2 and design §2–4.
//
// `unset` is part of the model even though v1 has no UI for it (scope red line: the
// model must reserve for out-of-scope features; `unset` lets a scene explicitly erase
// a base variable). Secret entries carry only a Keychain `account` reference — never a
// plaintext value (invariant #2).

/// The three value kinds a variable entry can take (spec §2.1).
public enum VarKind: String, Sendable, Equatable {
    case plain
    case secret
    case unset
}

/// One variable definition inside a layer.
///
/// The memberwise initializer is private so only the validated factories below can
/// build an entry — this keeps `plain` always paired with a `value`, `secret` always
/// paired with an `account` (and never a value), and `unset` with neither.
public struct VarEntry: Sendable, Equatable {
    public let name: String
    public let kind: VarKind
    /// Plaintext value for `.plain`; `nil` otherwise.
    public let value: String?
    /// Keychain account reference for `.secret`; `nil` otherwise. Never a plaintext key.
    public let account: String?

    private init(name: String, kind: VarKind, value: String?, account: String?) {
        self.name = name
        self.kind = kind
        self.value = value
        self.account = account
    }

    /// A plain variable exported with its literal value.
    public static func plain(_ name: String, _ value: String) -> VarEntry {
        VarEntry(name: name, kind: .plain, value: value, account: nil)
    }

    /// A secret variable; `account` is a Keychain reference (`{layer}/{VAR}`), not a key.
    public static func secret(_ name: String, account: String) -> VarEntry {
        VarEntry(name: name, kind: .secret, value: nil, account: account)
    }

    /// A variable explicitly erased at this layer (scene removing an inherited base var).
    public static func unset(_ name: String) -> VarEntry {
        VarEntry(name: name, kind: .unset, value: nil, account: nil)
    }
}

/// A named collection of variable definitions. v1 layers are `base` or a scene.
///
/// The layer's `name` comes from its file location (`base`, or the scene file stem),
/// not from the file contents — so the same TOML can be loaded under any name.
public struct Layer: Sendable, Equatable {
    public let name: String
    public let entries: [VarEntry]

    public init(name: String, entries: [VarEntry]) {
        self.name = name
        self.entries = entries
    }
}

/// Which layer a resolved variable came from (spec §3: every final var is traceable).
public enum Source: Sendable, Equatable {
    case base
    case scene(String)

    /// Display label for diffs/snapshots: `"base"` or the scene name.
    public var label: String {
        switch self {
        case .base: return "base"
        case let .scene(name): return name
        }
    }
}

/// A variable after evaluation, tagged with the layer it came from.
public struct ResolvedVar: Sendable, Equatable {
    public let entry: VarEntry
    public let source: Source

    public init(entry: VarEntry, source: Source) {
        self.entry = entry
        self.source = source
    }

    public var name: String { entry.name }

    /// Masked, plaintext-free display value for diffs/eval output:
    /// plain → its value, secret → `secret(<account>)`, unset → `unset`.
    /// A secret's plaintext is never available here (invariant #2).
    public var displayValue: String {
        switch entry.kind {
        case .plain: return entry.value ?? ""
        case .secret: return "secret(\(entry.account ?? ""))"
        case .unset: return "unset"
        }
    }
}

/// The full evaluated environment. Variables are kept sorted by name so serialization
/// and the generation fingerprint are deterministic regardless of input order.
public struct ResolvedEnv: Sendable, Equatable {
    public let vars: [ResolvedVar]

    public init(_ vars: [ResolvedVar]) {
        self.vars = vars.sorted { $0.name < $1.name }
    }

    /// Lookup by variable name (used by diff).
    public var byName: [String: ResolvedVar] {
        Dictionary(vars.map { ($0.name, $0) }, uniquingKeysWith: { _, last in last })
    }
}

/// Secret storage backend (config.toml `secret_backend`). `env` is the v1 fallback.
public enum SecretBackend: String, Sendable, Equatable {
    case keychain
    case env
}

/// Global settings from `config.toml`.
public struct GlobalConfig: Sendable, Equatable {
    /// Active scene name; `nil` means base-only.
    public var active: String?
    public var secretBackend: SecretBackend

    public init(active: String? = nil, secretBackend: SecretBackend = .keychain) {
        self.active = active
        self.secretBackend = secretBackend
    }
}

/// A single entry in a current→next diff (design §7).
public enum ChangeKind: String, Sendable, Equatable {
    case added
    case changed
    case removed
}

/// One variable's change in a diff preview. Carries the source layer and masked
/// display values — never plaintext (secrets compared by account reference only).
public struct Change: Sendable, Equatable {
    public let name: String
    public let kind: ChangeKind
    /// Source layer of the resulting var (`next` for added/changed, `current` for removed).
    public let source: Source
    public let oldDisplay: String?
    public let newDisplay: String?

    public init(name: String, kind: ChangeKind, source: Source, oldDisplay: String?, newDisplay: String?) {
        self.name = name
        self.kind = kind
        self.source = source
        self.oldDisplay = oldDisplay
        self.newDisplay = newDisplay
    }
}
