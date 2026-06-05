import Testing
@testable import EnvCueCore

// T0 skeleton: placeholder suite proving the module links and the test harness runs.
// Real evaluate/diff/serialize/generation tests arrive in T1.
@Test func moduleLinks() {
    #expect(EnvCueCore.module == "EnvCueCore")
}
