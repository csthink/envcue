import Testing
@testable import EnvCueShell

// T0 skeleton: placeholder suite proving the module links.
// Real atomic-write / shim idempotency / hook tests arrive in T3.
@Test func anchorsArePaired() {
    #expect(EnvCueShell.beginAnchor == "# >>> envcue >>>")
    #expect(EnvCueShell.endAnchor == "# <<< envcue <<<")
}
