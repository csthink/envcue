import Testing
@testable import EnvCueCore

// T1 acceptance (docs/tasks.md): evaluate · diff · serialize (no plaintext) · generation.
// Plus T1.2 TOML round-trip. All pure-logic, no filesystem/Keychain.

// MARK: - Evaluate (spec 验收 6: base kept, scene override, unset erase, source correct)

@Test func evaluateKeepsBaseOnlyVars() {
    let base = Layer(name: "base", entries: [.plain("EDITOR", "nvim")])
    let env = EnvCueCore.evaluate(base: base)
    let v = env.byName["EDITOR"]
    #expect(v?.entry == .plain("EDITOR", "nvim"))
    #expect(v?.source == .base)
}

@Test func evaluateSceneOverridesBase() {
    let base = Layer(name: "base", entries: [.plain("EDITOR", "nvim"), .plain("LANG", "C")])
    let scene = Layer(name: "work", entries: [.plain("EDITOR", "code")])
    let env = EnvCueCore.evaluate(base: base, scene: scene)

    #expect(env.byName["EDITOR"]?.entry.value == "code")
    #expect(env.byName["EDITOR"]?.source == .scene("work"))
    // base-only var survives, still tagged base
    #expect(env.byName["LANG"]?.entry.value == "C")
    #expect(env.byName["LANG"]?.source == .base)
}

@Test func evaluateUnsetErasesBaseVar() {
    let base = Layer(name: "base", entries: [.plain("JAVA_TOOL_OPTIONS", "-Xmx1g")])
    let scene = Layer(name: "work", entries: [.unset("JAVA_TOOL_OPTIONS")])
    let env = EnvCueCore.evaluate(base: base, scene: scene)
    #expect(env.byName["JAVA_TOOL_OPTIONS"] == nil)
    #expect(env.vars.isEmpty)
}

@Test func evaluateSecretCarriesAccountAndSource() {
    let base = Layer(name: "base", entries: [])
    let scene = Layer(name: "personal", entries: [.secret("OPENAI_API_KEY", account: "personal/OPENAI_API_KEY")])
    let env = EnvCueCore.evaluate(base: base, scene: scene)
    #expect(env.byName["OPENAI_API_KEY"]?.entry.account == "personal/OPENAI_API_KEY")
    #expect(env.byName["OPENAI_API_KEY"]?.source == .scene("personal"))
}

@Test func evaluateIsDeterministicAndSorted() {
    let base = Layer(name: "base", entries: [.plain("Z", "1"), .plain("A", "2"), .plain("M", "3")])
    let env = EnvCueCore.evaluate(base: base)
    #expect(env.vars.map(\.name) == ["A", "M", "Z"]) // sorted regardless of input order
}

// MARK: - Diff (added / changed / removed; secret only by reference; no plaintext)

@Test func diffDetectsAddedChangedRemoved() {
    let current = EnvCueCore.evaluate(base: Layer(name: "base", entries: [
        .plain("EDITOR", "nvim"),   // will change
        .plain("LANG", "C"),        // will be removed
    ]))
    let next = EnvCueCore.evaluate(base: Layer(name: "base", entries: [
        .plain("EDITOR", "code"),   // changed
        .plain("PAGER", "less"),    // added
    ]))
    let changes = EnvCueCore.diff(current: current, next: next)
    let byName = Dictionary(uniqueKeysWithValues: changes.map { ($0.name, $0) })

    #expect(byName["PAGER"]?.kind == .added)
    #expect(byName["EDITOR"]?.kind == .changed)
    #expect(byName["EDITOR"]?.oldDisplay == "nvim")
    #expect(byName["EDITOR"]?.newDisplay == "code")
    #expect(byName["LANG"]?.kind == .removed)
    #expect(changes.map(\.name) == ["EDITOR", "LANG", "PAGER"]) // sorted
}

@Test func diffSecretChangesOnlyByReference() {
    let a = EnvCueCore.evaluate(base: Layer(name: "base", entries: [.secret("KEY", account: "base/KEY")]))
    let sameRef = EnvCueCore.evaluate(base: Layer(name: "base", entries: [.secret("KEY", account: "base/KEY")]))
    let diffRef = EnvCueCore.evaluate(base: Layer(name: "base", entries: [.secret("KEY", account: "work/KEY")]))

    // identical account reference → no change (we never decrypt to compare)
    #expect(EnvCueCore.diff(current: a, next: sameRef).isEmpty)
    // changed account reference → a single `changed`, displayed as the masked reference
    let changes = EnvCueCore.diff(current: a, next: diffRef)
    #expect(changes.count == 1)
    #expect(changes[0].kind == .changed)
    #expect(changes[0].oldDisplay == "secret(base/KEY)")
    #expect(changes[0].newDisplay == "secret(work/KEY)")
}

@Test func diffIgnoresSourceOnlyChange() {
    // Same value, different source layer → environment unchanged → no diff entry,
    // consistent with the generation fingerprint (invariant #5).
    let base = EnvCueCore.evaluate(base: Layer(name: "base", entries: [.plain("EDITOR", "nvim")]))
    let viaScene = EnvCueCore.evaluate(
        base: Layer(name: "base", entries: []),
        scene: Layer(name: "work", entries: [.plain("EDITOR", "nvim")])
    )
    #expect(EnvCueCore.diff(current: base, next: viaScene).isEmpty)
}

// MARK: - Serialize (T1.5, G1): secret is a keychain-get reference; NO plaintext on disk

@Test func serializeEmitsPlainExportUnsetAndSecretReference() {
    let env = EnvCueCore.evaluate(
        base: Layer(name: "base", entries: [
            .plain("EDITOR", "nvim"),
            .secret("OPENAI_API_KEY", account: "personal/OPENAI_API_KEY"),
            .unset("JAVA_TOOL_OPTIONS"),
        ])
    )
    let text = EnvCueCore.serialize(env, activeScene: "personal")

    #expect(text.contains("export EDITOR=\"nvim\""))
    #expect(text.contains("export OPENAI_API_KEY=\"$(envcue keychain-get --account 'personal/OPENAI_API_KEY')\""))
    #expect(text.contains("unset JAVA_TOOL_OPTIONS 2>/dev/null"))
    #expect(text.contains("# AUTO-GENERATED by envcue"))
    #expect(text.contains("generation=\(EnvCueCore.generation(env))"))
    #expect(text.contains("_ENVCUE_NOTICE='%F{cyan}envcue%f → personal'"))
}

@Test func serializeNeverLeaksPlaintextSecret() {
    // The plaintext below is the imagined Keychain value. It must NEVER reach the
    // snapshot — the model has no field that could carry it, and the snapshot only
    // names the account reference (NFR-1, invariant #2).
    let plaintext = "sk-supersecret-DO-NOT-LEAK-1234567890"
    let env = EnvCueCore.evaluate(
        base: Layer(name: "base", entries: [.secret("OPENAI_API_KEY", account: "personal/OPENAI_API_KEY")])
    )
    let text = EnvCueCore.serialize(env, activeScene: "personal")
    #expect(!text.contains(plaintext))
    #expect(!text.contains("sk-"))
    // What *is* present is only the non-secret account reference.
    #expect(text.contains("--account 'personal/OPENAI_API_KEY'"))
}

@Test func serializeBaseOnlyNoticeSaysBase() {
    let env = EnvCueCore.evaluate(base: Layer(name: "base", entries: [.plain("A", "1")]))
    let text = EnvCueCore.serialize(env, activeScene: nil)
    #expect(text.contains("_ENVCUE_NOTICE='%F{cyan}envcue%f → base'"))
}

@Test func serializeEscapesDangerousPlainValues() {
    let env = EnvCueCore.evaluate(base: Layer(name: "base", entries: [
        .plain("TRICKY", "a\"b$c`d\\e"),
    ]))
    let text = EnvCueCore.serialize(env, activeScene: nil)
    // Each shell metacharacter is backslash-escaped inside the double quotes.
    #expect(text.contains("export TRICKY=\"a\\\"b\\$c\\`d\\\\e\""))
}

@Test func serializeEscapesSingleQuotesInSceneNameAndAccount() {
    // Scene names and accounts are user-controlled and land inside single-quoted shell
    // strings (the secret line's `--account '...'` and the `_ENVCUE_NOTICE='… → <scene>'`).
    // A literal `'` must be neutralized via the `'\''` idiom, or it would break the quoting
    // and could inject zsh into the sourced snapshot.
    let env = EnvCueCore.evaluate(base: Layer(name: "base", entries: [
        .secret("K", account: "wei'rd/ACCOUNT"),
    ]))
    let text = EnvCueCore.serialize(env, activeScene: "ev'il")
    #expect(text.contains("--account 'wei'\\''rd/ACCOUNT'"))
    #expect(text.contains("→ ev'\\''il'"))
}

// MARK: - Generation (T1.6, invariant #5): content-only fingerprint, scene-name-free

@Test func generationStableForSameContent() {
    let env1 = EnvCueCore.evaluate(base: Layer(name: "base", entries: [.plain("A", "1"), .plain("B", "2")]))
    let env2 = EnvCueCore.evaluate(base: Layer(name: "base", entries: [.plain("B", "2"), .plain("A", "1")]))
    #expect(EnvCueCore.generation(env1) == EnvCueCore.generation(env2)) // order-independent
}

@Test func generationEqualWhenTwoScenesResolveSameEnv() {
    // The honesty premise (design §6.1): two *different* scenes that resolve to the
    // same exported environment share a generation → switching prints no false notice.
    let base = Layer(name: "base", entries: [])
    let sceneX = Layer(name: "x", entries: [.plain("EDITOR", "nvim"), .secret("K", account: "shared/K")])
    let sceneY = Layer(name: "y", entries: [.plain("EDITOR", "nvim"), .secret("K", account: "shared/K")])
    let envX = EnvCueCore.evaluate(base: base, scene: sceneX)
    let envY = EnvCueCore.evaluate(base: base, scene: sceneY)
    #expect(envX.byName["EDITOR"]?.source != envY.byName["EDITOR"]?.source) // sources differ...
    #expect(EnvCueCore.generation(envX) == EnvCueCore.generation(envY))     // ...fingerprint does not
}

@Test func generationChangesWhenContentChanges() {
    let env1 = EnvCueCore.evaluate(base: Layer(name: "base", entries: [.plain("A", "1")]))
    let env2 = EnvCueCore.evaluate(base: Layer(name: "base", entries: [.plain("A", "2")]))
    let env3 = EnvCueCore.evaluate(base: Layer(name: "base", entries: [.secret("A", account: "base/A")]))
    #expect(EnvCueCore.generation(env1) != EnvCueCore.generation(env2)) // value differs
    #expect(EnvCueCore.generation(env1) != EnvCueCore.generation(env3)) // kind differs
}

@Test func generationDiffersWhenSecretAccountDiffers() {
    let env1 = EnvCueCore.evaluate(base: Layer(name: "base", entries: [.secret("K", account: "personal/K")]))
    let env2 = EnvCueCore.evaluate(base: Layer(name: "base", entries: [.secret("K", account: "work/K")]))
    #expect(EnvCueCore.generation(env1) != EnvCueCore.generation(env2))
}

// MARK: - TOML round-trip (T1.2)

@Test func layerRoundTripPreservesAllKinds() throws {
    let layer = Layer(name: "personal", entries: [
        .plain("EDITOR", "nvim"),
        .secret("OPENAI_API_KEY", account: "personal/OPENAI_API_KEY"),
        .unset("JAVA_TOOL_OPTIONS"),
    ])
    let toml = EnvCueCore.saveLayer(layer)
    let reloaded = try EnvCueCore.loadLayer(name: "personal", toml: toml)
    // entries are stored sorted by name on the way out; compare as sets-by-name
    #expect(Set(reloaded.entries.map(\.name)) == Set(layer.entries.map(\.name)))
    #expect(reloaded.entries.first { $0.name == "EDITOR" } == .plain("EDITOR", "nvim"))
    #expect(reloaded.entries.first { $0.name == "OPENAI_API_KEY" } == .secret("OPENAI_API_KEY", account: "personal/OPENAI_API_KEY"))
    #expect(reloaded.entries.first { $0.name == "JAVA_TOOL_OPTIONS" } == .unset("JAVA_TOOL_OPTIONS"))
}

@Test func layerSaveOmitsPlaintextForSecret() {
    let layer = Layer(name: "p", entries: [.secret("K", account: "p/K")])
    let toml = EnvCueCore.saveLayer(layer)
    // A secret persists only its account reference (quote style is TOMLKit's choice).
    #expect(toml.contains("account"))
    #expect(toml.contains("p/K"))
    #expect(!toml.contains("value")) // no plaintext value field for a secret
}

@Test func loadLayerRejectsMissingField() {
    let toml = """
    [vars.OPENAI_API_KEY]
    kind = "secret"
    """
    #expect(throws: EnvCueCoreError.self) {
        _ = try EnvCueCore.loadLayer(name: "p", toml: toml)
    }
}

@Test func loadLayerRejectsUnknownKind() {
    let toml = """
    [vars.X]
    kind = "bogus"
    """
    #expect(throws: EnvCueCoreError.self) {
        _ = try EnvCueCore.loadLayer(name: "p", toml: toml)
    }
}

@Test func configRoundTrip() throws {
    let config = GlobalConfig(active: "work", secretBackend: .keychain)
    let reloaded = try EnvCueCore.loadConfig(toml: EnvCueCore.saveConfig(config))
    #expect(reloaded == config)
}

@Test func configBaseOnlyOmitsActive() throws {
    let config = GlobalConfig(active: nil, secretBackend: .env)
    let toml = EnvCueCore.saveConfig(config)
    #expect(!toml.contains("active"))
    let reloaded = try EnvCueCore.loadConfig(toml: toml)
    #expect(reloaded.active == nil)
    #expect(reloaded.secretBackend == .env)
}

@Test func configEmptyActiveTreatedAsBaseOnly() throws {
    let reloaded = try EnvCueCore.loadConfig(toml: "active = \"\"\nsecret_backend = \"keychain\"\n")
    #expect(reloaded.active == nil)
}

// Error messages never echo a secret value (project rule: Err.Display forbids keys).
@Test func errorDescriptionsAreReadableAndKeyFree() {
    #expect(EnvCueCoreError.missingField(name: "OPENAI_API_KEY", field: "account").description
        == "envcue: variable 'OPENAI_API_KEY' is missing required field 'account'")
    #expect(EnvCueCoreError.unknownValue(context: "secret_backend", value: "vault").description
        == "envcue: unknown value 'vault' in secret_backend")
}
