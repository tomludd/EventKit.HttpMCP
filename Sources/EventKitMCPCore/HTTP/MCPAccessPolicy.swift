import CryptoKit
import Foundation
import Security

/// Who may talk to the MCP HTTP server.
///
/// - Loopback clients (this Mac) are always allowed and need no API key: any local process can read
///   the key from config.json anyway, and browsers are kept out by the Host and Origin checks.
/// - With no allowed networks the server listens on loopback only.
/// - With allowed networks it listens on all interfaces, accepts peers inside those networks, and
///   every request from a non-loopback peer must carry the API key.
public struct MCPAccessPolicy: Equatable, Sendable {
    public var allowedNetworks: [CIDRRange]
    public var apiKey: String?

    public init(allowedNetworks: [CIDRRange] = [], apiKey: String? = nil) {
        self.allowedNetworks = allowedNetworks
        self.apiKey = apiKey
    }

    public static let localOnly = MCPAccessPolicy()

    /// The server listens on all interfaces instead of loopback only.
    public var allowsNetworkClients: Bool { !allowedNetworks.isEmpty }

    /// Whether a connection from `address` is accepted at all. Unknown addresses are refused.
    public func allowsConnection(from address: InternetAddress?) -> Bool {
        guard let address else { return false }
        return address.isLoopback || allowedNetworks.contains { $0.contains(address) }
    }

    /// Requests from anything but loopback need the API key.
    public func requiresAPIKey(from address: InternetAddress?) -> Bool {
        address?.isLoopback != true
    }

    /// The request carries the API key in `Authorization: Bearer <key>` or `X-API-Key: <key>`.
    /// Either header is enough. Without a configured key nothing is authorized.
    public func isAuthorized(_ request: HTTPRequest) -> Bool {
        guard let apiKey, !apiKey.isEmpty else { return false }
        var matched = false
        // Check every candidate so the time taken does not depend on which header matched.
        for candidate in Self.presentedKeys(in: request.headers) {
            matched = Self.constantTimeEquals(candidate, apiKey) || matched
        }
        return matched
    }

    static func presentedKeys(in headers: [String: String]) -> [String] {
        var keys: [String] = []
        if let authorization = headers["authorization"]?.trimmingCharacters(in: .whitespaces) {
            let parts = authorization.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            if parts.count == 2, parts[0].lowercased() == "bearer" {
                keys.append(parts[1].trimmingCharacters(in: .whitespaces))
            }
        }
        if let header = headers["x-api-key"]?.trimmingCharacters(in: .whitespaces), !header.isEmpty {
            keys.append(header)
        }
        return keys
    }

    /// Compares SHA-256 digests byte by byte without early exit, so neither the key's length nor
    /// the position of the first difference shows in the timing.
    static func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
        let a = Array(SHA256.hash(data: Data(lhs.utf8)))
        let b = Array(SHA256.hash(data: Data(rhs.utf8)))
        var difference: UInt8 = 0
        for index in a.indices { difference |= a[index] ^ b[index] }
        return difference == 0
    }

    /// 32 random bytes, base64url without padding, prefixed so the key is recognizable.
    public static func generateAPIKey() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess {
            var generator = SystemRandomNumberGenerator()
            bytes = bytes.map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        }
        let encoded = Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "ekmcp_" + encoded
    }
}
