import Testing
@testable import EnvCueCore

// PROPOSAL-002 (security gate G3): the generation fingerprint's canonical encoding must be
// injective for ANY value bytes. An earlier version framed fields with \u{0}/\u{1} and
// assumed those bytes never appear in a value — false for arbitrary plain values, which
// let two genuinely different environments collide on one fingerprint and silently break
// the "honest, content-only generation" floor (invariant #5 / NFR-2). These lock the
// length-prefixed encoding that removes the collision without restricting value content.

@Test func generationDoesNotCollideOnValuesContainingFramingBytes() {
    let oneVarForgedRecord = EnvCueCore.evaluate(base: Layer(name: "base", entries: [
        .plain("A", "x\u{1}B\u{0}plain\u{0}y"), // value forges a second "B=y" record
    ]))
    let twoRealVars = EnvCueCore.evaluate(base: Layer(name: "base", entries: [
        .plain("A", "x"),
        .plain("B", "y"),
    ]))
    // Identical under the old separator scheme; distinct under length-prefix framing.
    #expect(EnvCueCore.generation(oneVarForgedRecord) != EnvCueCore.generation(twoRealVars))
}

@Test func generationDistinguishesFieldBoundaries() {
    // ("AB", value "") vs ("A", value "B") differ only in where the name ends — the
    // length prefixes must keep them distinct.
    let ab = EnvCueCore.evaluate(base: Layer(name: "base", entries: [.plain("AB", "")]))
    let a_b = EnvCueCore.evaluate(base: Layer(name: "base", entries: [.plain("A", "B")]))
    #expect(EnvCueCore.generation(ab) != EnvCueCore.generation(a_b))
}
