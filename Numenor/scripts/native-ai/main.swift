import Foundation
import Security
#if canImport(FoundationModels)
import FoundationModels
#endif

struct Request: Decodable {
    let action: String
    let provider: String?
    let value: String?
    let scope: String?
}

struct BridgeError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

func appleStatus() -> String {
    #if canImport(FoundationModels)
    if #available(macOS 26.0, *) {
        switch SystemLanguageModel.default.availability {
        case .available: return "available"
        case .unavailable(.deviceNotEligible): return "This Mac does not support Apple Intelligence."
        case .unavailable(.appleIntelligenceNotEnabled): return "Turn on Apple Intelligence in System Settings."
        case .unavailable(.modelNotReady): return "The system model is still being prepared by macOS."
        @unknown default: return "The macOS system model is unavailable."
        }
    }
    #endif
    return "Apple Foundation Models requires macOS 26 or later."
}

func keychain(_ request: Request) throws -> String {
    guard let provider = request.provider, ["openai", "gemini", "ollama"].contains(provider),
          let scope = request.scope, scope.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil else {
        throw BridgeError(message: "Unknown credential provider.")
    }
    let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "com.farhadshad.numenor.ai",
        kSecAttrAccount as String: "\(provider):\(scope)"
    ]
    let status: OSStatus
    if request.action == "key-read" {
        var lookup = query
        lookup[kSecReturnData as String] = true
        var result: CFTypeRef?
        status = SecItemCopyMatching(lookup as CFDictionary, &result)
        if status == errSecSuccess, let data = result as? Data { return String(decoding: data, as: UTF8.self) }
        if status == errSecItemNotFound { return "" }
    } else if let value = request.value, !value.isEmpty {
        let attributes = [kSecValueData as String: Data(value.utf8)]
        let update = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        status = update == errSecItemNotFound
            ? SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil) : update
    } else {
        status = SecItemDelete(query as CFDictionary)
        if status == errSecItemNotFound { return "" }
    }
    guard status == errSecSuccess else {
        throw BridgeError(message: "Keychain error (\(status)). Unlock the login Keychain and retry.")
    }
    return ""
}

do {
    let request = try JSONDecoder().decode(Request.self, from: FileHandle.standardInput.readDataToEndOfFile())
    let value: String
    switch request.action {
    case "apple-status":
        value = appleStatus()
    case "apple-generate":
        let status = appleStatus()
        guard status == "available" else { throw BridgeError(message: status) }
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            let response = try await LanguageModelSession().respond(to: request.value ?? "")
            value = response.content
        } else {
            throw BridgeError(message: status)
        }
        #else
        throw BridgeError(message: status)
        #endif
    case "key-read", "key-write":
        value = try keychain(request)
    default:
        throw BridgeError(message: "Unknown native AI action.")
    }
    FileHandle.standardOutput.write(try JSONEncoder().encode(value))
} catch {
    FileHandle.standardError.write(Data(error.localizedDescription.utf8))
    exit(1)
}
