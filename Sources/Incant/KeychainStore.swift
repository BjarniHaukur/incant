import Foundation
import OSLog
import Security

enum KeychainStore {
    private static let logger = Logger(subsystem: "com.bjarni.Incant", category: "Keychain")
    private static let service = "com.bjarni.Incant"
    private static let account = "openai-api-key"

    /// Whether a key has ever been saved here — a plain boolean, never the secret.
    ///
    /// Reading the Keychain can raise a system prompt, and the settings row needs
    /// to know whether a key exists on every redraw. Asking the Keychain that
    /// question once a second is what made Incant beg for permission in a loop, so
    /// the question is answered from here and the Keychain is only opened when the
    /// key itself is actually needed.
    private static let presenceKey = "hasStoredAPIKey"
    static var hasStoredKey: Bool { UserDefaults.standard.bool(forKey: presenceKey) }

    /// Resolved once per launch, denial included: if the user says no, Incant takes
    /// no for an answer until it is next launched.
    nonisolated(unsafe) private static var resolvedStoredKey: String??

    static func save(_ value: String) throws {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        var insert = query
        insert[kSecValueData as String] = data
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(insert as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
        resolvedStoredKey = value
        UserDefaults.standard.set(true, forKey: presenceKey)
    }

    /// A key typed into Incant beats one lying around in the environment. It was
    /// the other way round, which made the settings row unchangeable: saving a new
    /// key did nothing anyone could observe, because the variable still won.
    static func load() -> String? { storedKey() ?? environmentKey() }

    static func storedKey() -> String? {
        if let resolvedStoredKey { return resolvedStoredKey }
        // Never open the Keychain looking for something that was never put there:
        // a miss is silent, but a hit on an item signed by an earlier build is not.
        guard hasStoredKey else {
            resolvedStoredKey = .some(nil)
            return nil
        }
        let key = readStoredKey()
        if key == nil {
            logger.error("Keychain access refused or key missing; using the environment for now")
        }
        resolvedStoredKey = key
        return key
    }

    private static func readStoredKey() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func forgetStoredKey() {
        resolvedStoredKey = .some(nil)
        UserDefaults.standard.set(false, forKey: presenceKey)
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ] as CFDictionary)
    }

    /// Resolved once per launch. The settings row asks whether the environment has
    /// a key on every redraw, and answering it spawns a login shell.
    nonisolated(unsafe) private static var resolvedEnvironmentKey: String??

    static func environmentKey() -> String? {
        if let resolvedEnvironmentKey { return resolvedEnvironmentKey }
        let key = resolveEnvironmentKey()
        resolvedEnvironmentKey = key
        return key
    }

    private static func resolveEnvironmentKey() -> String? {
        if let key = validKey(ProcessInfo.processInfo.environment["OPENAI_API_KEY"]) {
            return key
        }
        if let key = validKey(run("/bin/launchctl", ["getenv", "OPENAI_API_KEY"])) {
            return key
        }
        // Dock apps do not inherit interactive shell variables. Resolve the
        // user's login-shell environment without ever persisting the result.
        let shellOutput = run("/bin/zsh", ["-lic", "print -rn -- \"${OPENAI_API_KEY:-}\""])
        return extractKey(from: shellOutput)
    }

    private static func run(_ executable: String, _ arguments: [String]) -> String? {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let data = output.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)
        } catch {
            return nil
        }
    }

    private static func extractKey(from output: String?) -> String? {
        guard let output else { return nil }
        if let direct = validKey(output.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return direct
        }
        let pattern = #"sk-[A-Za-z0-9_-]+"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(output.startIndex..., in: output)
        guard let match = regex.matches(in: output, range: range).last,
              let swiftRange = Range(match.range, in: output) else { return nil }
        return validKey(String(output[swiftRange]))
    }

    private static func validKey(_ value: String?) -> String? {
        guard let value, value.hasPrefix("sk-"), !value.contains(where: \.isWhitespace) else { return nil }
        return value
    }
}
