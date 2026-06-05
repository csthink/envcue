import Testing
@testable import EnvCueKeychain

// T0 skeleton: placeholder suite proving the module links.
// Real Keychain round-trip / stdout tests arrive in T2.
@Test func serviceIdentifier() {
    #expect(EnvCueKeychain.service == "dev.mars.envcue")
}
