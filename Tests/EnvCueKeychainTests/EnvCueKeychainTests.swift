import Testing
import Foundation
@testable import EnvCueKeychain

// MARK: - Fake store (in-memory, no Keychain) for always-on unit tests.

/// Reference-typed in-memory KeychainStore. `@unchecked Sendable` with an NSLock because
/// the protocol requires Sendable; the lock keeps the dictionary access correct.
final class FakeKeychainStore: KeychainStore, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: String] = [:]

    func set(account: String, value: String) throws {
        lock.lock(); defer { lock.unlock() }
        storage[account] = value
    }
    func get(account: String) throws -> String? {
        lock.lock(); defer { lock.unlock() }
        return storage[account]
    }
    func delete(account: String) throws {
        lock.lock(); defer { lock.unlock() }
        storage[account] = nil
    }
}

// MARK: - Identity / helpers

@Test func serviceIdentifier() {
    #expect(EnvCueKeychain.service == "dev.mars.envcue")
}

@Test func accountDerivation() {
    #expect(EnvCueKeychain.account(layer: "personal", variable: "OPENAI_API_KEY")
        == "personal/OPENAI_API_KEY")
}

// MARK: - Store contract (via fake, no real Keychain)

@Test func storeRoundTripAndIdempotentDelete() throws {
    let store = FakeKeychainStore()
    #expect(try store.get(account: "base/X") == nil)

    try store.set(account: "base/X", value: "sk-secret-123")
    #expect(try store.get(account: "base/X") == "sk-secret-123")

    // Overwrite (the SystemKeychainStore update path is exercised in INTEGRATION).
    try store.set(account: "base/X", value: "sk-secret-456")
    #expect(try store.get(account: "base/X") == "sk-secret-456")

    try store.delete(account: "base/X")
    #expect(try store.get(account: "base/X") == nil)
    // Deleting an absent entry must not throw (idempotent contract).
    try store.delete(account: "base/X")
}

// MARK: - keychain-get read path (T2.2)

@Test func keychainGetWritesRawValueToStdout() throws {
    let store = FakeKeychainStore()
    // A value with an interior newline and no trailing newline: proves we emit raw bytes
    // and append nothing.
    let secret = "sk-line1\nno-trailing-newline-added"
    try store.set(account: "work/TOK", value: secret)

    let pipe = Pipe()
    try EnvCueKeychain.keychainGet(account: "work/TOK", store: store, to: pipe.fileHandleForWriting)
    try pipe.fileHandleForWriting.close()

    let data = try pipe.fileHandleForReading.readToEnd() ?? Data()
    #expect(String(data: data, encoding: .utf8) == secret)
    // Byte-exact: no newline (or anything else) appended.
    #expect(data.count == Data(secret.utf8).count)
}

@Test func keychainGetThrowsNotFoundForAbsentAccount() {
    let store = FakeKeychainStore()
    #expect(throws: KeychainError.notFound(account: "missing/VAR")) {
        try EnvCueKeychain.keychainGet(
            account: "missing/VAR",
            store: store,
            to: Pipe().fileHandleForWriting
        )
    }
}

// MARK: - Invariant #2: error messages never leak a secret value

@Test func errorMessagesAreReadableAndSecretFree() {
    // The cases structurally cannot carry a value; this asserts the Display text stays
    // account/status-only so a future edit can't smuggle a key into an error.
    let probe = "sk-super-secret-DEADBEEF"
    let errors: [KeychainError] = [
        .notFound(account: "personal/OPENAI_API_KEY"),
        .unexpectedData(account: "personal/OPENAI_API_KEY"),
        .unhandled(status: -25300),
    ]
    for e in errors {
        #expect(!e.description.contains(probe))
        #expect(e.description.hasPrefix("envcue: "))
    }
}

// MARK: - Integration: the real Security-backed store

#if INTEGRATION
// Hits the real (login) Keychain. Run with:
//   DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test -Xswiftc -DINTEGRATION
// May trigger a Keychain access prompt. Uses a throwaway account, cleaned up in defer.
@Test func systemKeychainRoundTrip() throws {
    let store = SystemKeychainStore()
    let account = "envcue-integration-test/PROBE"
    try? store.delete(account: account)
    defer { try? store.delete(account: account) }

    try store.set(account: account, value: "probe-value-1")
    #expect(try store.get(account: account) == "probe-value-1")

    // Update path: a second set overwrites in place.
    try store.set(account: account, value: "probe-value-2")
    #expect(try store.get(account: account) == "probe-value-2")

    try store.delete(account: account)
    #expect(try store.get(account: account) == nil)
}
#endif
