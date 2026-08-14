import Foundation
import Security

enum KeychainStore {
    private static let service = "com.bjarni.PushType"
    private static let account = "openai-api-key"

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
    }

    static func load() -> String? {
        if let environmentKey = environmentKey() { return environmentKey }
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

    static func environmentKey() -> String? {
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
