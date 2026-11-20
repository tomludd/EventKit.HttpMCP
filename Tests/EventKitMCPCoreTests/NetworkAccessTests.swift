import Foundation
import Network
import Testing
@testable import EventKitMCPCore

struct InternetAddressTests {
    @Test func parsesIPv4AndIPv6() throws {
        #expect(try #require(InternetAddress("192.168.1.5")).bytes == [192, 168, 1, 5])
        #expect(try #require(InternetAddress(" 10.0.0.1 ")).description == "10.0.0.1")
        let v6 = try #require(InternetAddress("fd00::1"))
        #expect(!v6.isIPv4 && v6.bytes.count == 16 && v6.description == "fd00::1")
        #expect(InternetAddress("::1") == .loopbackV6)
    }

    @Test func storesIPv4MappedIPv6AsIPv4() throws {
        let mapped = try #require(InternetAddress("::ffff:192.168.1.5"))
        #expect(mapped.isIPv4)
        #expect(mapped == InternetAddress("192.168.1.5"))
        #expect(InternetAddress("::ffff:127.0.0.1")?.isLoopback == true)
    }

    @Test func rejectsInvalidAddresses() {
        for text in ["", "256.1.1.1", "1.2.3", "1.2.3.4.5", "abc", "fe80::1%en0", "[::1]", "1.2.3.4:80", "::g", "1:2:3:4:5:6:7:8:9"] {
            #expect(InternetAddress(text) == nil, "\(text)")
        }
    }

    @Test func loopback() {
        #expect(InternetAddress("127.0.0.1")!.isLoopback)
        #expect(InternetAddress("127.8.9.10")!.isLoopback)
        #expect(InternetAddress("::1")!.isLoopback)
        #expect(!InternetAddress("128.0.0.1")!.isLoopback)
        #expect(!InternetAddress("::2")!.isLoopback)
        #expect(!InternetAddress("192.168.1.1")!.isLoopback)
    }

    @Test func readsNetworkEndpoints() {
        #expect(InternetAddress(host: .ipv4(IPv4Address("10.1.2.3")!)) == InternetAddress("10.1.2.3"))
        #expect(InternetAddress(host: .ipv6(IPv6Address("::ffff:10.1.2.3")!)) == InternetAddress("10.1.2.3"))
        #expect(InternetAddress(host: .ipv6(IPv6Address("fd00::5")!)) == InternetAddress("fd00::5"))
        #expect(InternetAddress(host: .name("localhost", nil)) == .loopbackV4)
        #expect(InternetAddress(host: .name("example.com", nil)) == nil)
    }
}

struct CIDRRangeTests {
    @Test func parsesAndNormalizesIPv4() throws {
        let range = try #require(CIDRRange("192.168.1.77/24"))
        #expect(range.description == "192.168.1.0/24")
        #expect(range.contains(InternetAddress("192.168.1.1")!))
        #expect(range.contains(InternetAddress("192.168.1.255")!))
        #expect(!range.contains(InternetAddress("192.168.2.1")!))
        #expect(CIDRRange("10.0.0.0/9")!.contains(InternetAddress("10.127.255.255")!))
        #expect(!CIDRRange("10.0.0.0/9")!.contains(InternetAddress("10.128.0.0")!))
    }

    @Test func singleHostsWithSlash32AndBareAddresses() throws {
        let host = try #require(CIDRRange("10.0.0.5/32"))
        #expect(host.contains(InternetAddress("10.0.0.5")!))
        #expect(!host.contains(InternetAddress("10.0.0.6")!))
        #expect(CIDRRange("10.0.0.5") == host)
        #expect(CIDRRange("fd00::5") == CIDRRange("fd00::5/128"))
    }

    @Test func slashZeroMatchesItsWholeFamilyOnly() throws {
        let allV4 = try #require(CIDRRange("0.0.0.0/0"))
        #expect(allV4.matchesEverything)
        #expect(allV4.contains(InternetAddress("8.8.8.8")!))
        #expect(!allV4.contains(InternetAddress("fd00::1")!))
        let allV6 = try #require(CIDRRange("::/0"))
        #expect(allV6.contains(InternetAddress("2001:db8::1")!))
        #expect(!allV6.contains(InternetAddress("8.8.8.8")!))
        #expect(CIDRRange("1.2.3.4/0")?.description == "0.0.0.0/0")
    }

    @Test func matchesIPv6() throws {
        let ula = try #require(CIDRRange("fd00::/8"))
        #expect(ula.contains(InternetAddress("fd12:3456::1")!))
        #expect(!ula.contains(InternetAddress("fe80::1")!))
        let host = try #require(CIDRRange("2001:db8::1/128"))
        #expect(host.contains(InternetAddress("2001:db8::1")!))
        #expect(!host.contains(InternetAddress("2001:db8::2")!))
        #expect(CIDRRange("2001:db8:abcd:12ff::/60")?.description == "2001:db8:abcd:12f0::/60")
    }

    @Test func ipv4MappedPeersMatchIPv4Ranges() throws {
        let range = try #require(CIDRRange("192.168.1.0/24"))
        #expect(range.contains(InternetAddress("::ffff:192.168.1.9")!))
        // A mapped network written in IPv6 notation is the same IPv4 network.
        #expect(CIDRRange("::ffff:192.168.1.0/120") == range)
        #expect(CIDRRange("::ffff:0:0/96")?.description == "0.0.0.0/0")
        // Shorter prefixes would reach past the mapped block.
        #expect(CIDRRange("::ffff:192.168.1.0/95") == nil)
    }

    @Test func rejectsInvalidInput() {
        for text in ["", "/24", "192.168.1.0/", "192.168.1.0/33", "192.168.1.0/-1", "192.168.1.0/+24", "192.168.1.0/ 24",
                     "192.168.1.0/24/1", "192.168.1/24", "fd00::/129", "fd00::/abc", "example.com/24", "fe80::1%en0/64",
                     "192.168.1.0/0024"] {
            #expect(CIDRRange(text) == nil, "\(text)")
        }
    }
}

struct MCPAccessPolicyTests {
    let lan = InternetAddress("192.168.1.20")!
    let other = InternetAddress("10.0.0.20")!
    let policy = MCPAccessPolicy(allowedNetworks: [CIDRRange("192.168.1.0/24")!, CIDRRange("fd00::/8")!], apiKey: "secret-key")

    @Test func localOnlyByDefault() {
        let config = AppConfig()
        #expect(config.allowedClientCIDRs.isEmpty && config.apiKey == nil)
        #expect(config.accessPolicy == .localOnly)
        #expect(!config.allowsNetworkClients)
        let local = MCPAccessPolicy.localOnly
        #expect(local.allowsConnection(from: .loopbackV4))
        #expect(local.allowsConnection(from: .loopbackV6))
        #expect(local.allowsConnection(from: InternetAddress("::ffff:127.0.0.1")))
        #expect(!local.allowsConnection(from: lan))
        #expect(!local.allowsConnection(from: nil))
        #expect(LocalHTTPServer(port: 8765, handler: { _ in HTTPResponse(status: 200) }).listensOnNetwork == false)
    }

    @Test func acceptsAllowedNetworksAndLoopbackOnly() {
        #expect(policy.allowsNetworkClients)
        #expect(policy.allowsConnection(from: .loopbackV4))
        #expect(policy.allowsConnection(from: lan))
        #expect(policy.allowsConnection(from: InternetAddress("::ffff:192.168.1.20")))
        #expect(policy.allowsConnection(from: InternetAddress("fd99::1")))
        #expect(!policy.allowsConnection(from: other))
        #expect(!policy.allowsConnection(from: InternetAddress("2001:db8::1")))
        #expect(!policy.allowsConnection(from: nil))
        #expect(LocalHTTPServer(port: 8765, accessPolicy: policy, handler: { _ in HTTPResponse(status: 200) }).listensOnNetwork)
    }

    @Test func apiKeyIsRequiredFromEverythingButLoopback() {
        #expect(!policy.requiresAPIKey(from: .loopbackV4))
        #expect(!policy.requiresAPIKey(from: .loopbackV6))
        #expect(policy.requiresAPIKey(from: lan))
        #expect(policy.requiresAPIKey(from: nil))
    }

    func request(_ headers: [String: String]) -> HTTPRequest {
        HTTPRequest(method: "POST", path: "/mcp", headers: headers, remoteAddress: lan)
    }

    @Test func checksAPIKeyHeaders() {
        #expect(!policy.isAuthorized(request([:])))
        #expect(!policy.isAuthorized(request(["authorization": "Bearer wrong"])))
        #expect(!policy.isAuthorized(request(["x-api-key": "wrong"])))
        #expect(!policy.isAuthorized(request(["authorization": "Basic secret-key"])))
        #expect(!policy.isAuthorized(request(["authorization": "secret-key"])))
        #expect(!policy.isAuthorized(request(["x-api-key": "secret-key-and-more"])))
        #expect(!policy.isAuthorized(request(["x-api-key": "secret-ke"])))
        #expect(policy.isAuthorized(request(["authorization": "Bearer secret-key"])))
        #expect(policy.isAuthorized(request(["authorization": "bearer  secret-key "])))
        #expect(policy.isAuthorized(request(["x-api-key": "secret-key"])))
        // Both headers: either carrying the key is enough.
        #expect(policy.isAuthorized(request(["authorization": "Bearer secret-key", "x-api-key": "secret-key"])))
        #expect(policy.isAuthorized(request(["authorization": "Bearer wrong", "x-api-key": "secret-key"])))
        #expect(policy.isAuthorized(request(["authorization": "Bearer secret-key", "x-api-key": "wrong"])))
        #expect(!policy.isAuthorized(request(["authorization": "Bearer wrong", "x-api-key": "wrong"])))
    }

    @Test func nothingIsAuthorizedWithoutAKey() {
        let keyless = MCPAccessPolicy(allowedNetworks: policy.allowedNetworks, apiKey: nil)
        #expect(!keyless.isAuthorized(request(["authorization": "Bearer "])))
        #expect(!keyless.isAuthorized(request(["x-api-key": ""])))
        let empty = MCPAccessPolicy(allowedNetworks: policy.allowedNetworks, apiKey: "")
        #expect(!empty.isAuthorized(request(["authorization": "Bearer "])))
    }

    @Test func constantTimeComparison() {
        #expect(MCPAccessPolicy.constantTimeEquals("abc", "abc"))
        #expect(!MCPAccessPolicy.constantTimeEquals("abc", "abd"))
        #expect(!MCPAccessPolicy.constantTimeEquals("abc", "abcd"))
        #expect(!MCPAccessPolicy.constantTimeEquals("", "a"))
    }

    @Test func generatesRandomURLSafeKeys() {
        let a = MCPAccessPolicy.generateAPIKey()
        let b = MCPAccessPolicy.generateAPIKey()
        #expect(a != b)
        #expect(a.hasPrefix("ekmcp_") && a.count == 6 + 43)
        #expect(a.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") })
    }
}

struct NetworkAccessHandlerTests {
    static let key = "test-key-123"
    let handler: MCPHTTPHandler = {
        let server = MCPServer(name: "test", version: "1.0", instructions: { "hello" })
        return MCPHTTPHandler(server: server, accessPolicy: MCPAccessPolicy(
            allowedNetworks: [CIDRRange("192.168.1.0/24")!, CIDRRange("fd00::/8")!], apiKey: key
        ))
    }()

    func ping(from address: InternetAddress?, host: String = "192.168.1.2:8765", headers extra: [String: String] = [:]) -> HTTPResponse {
        var headers = ["host": host, "content-type": "application/json"]
        headers.merge(extra) { $1 }
        return handler.handle(HTTPRequest(method: "POST", path: "/mcp", headers: headers,
                                          body: Data(#"{"jsonrpc":"2.0","id":1,"method":"ping"}"#.utf8), remoteAddress: address))
    }

    @Test func remoteClientsInAllowedNetworksNeedTheKey() {
        let lan = InternetAddress("192.168.1.50")
        let missing = ping(from: lan)
        #expect(missing.status == 401)
        #expect(missing.headers.contains { $0.0 == "WWW-Authenticate" })
        #expect(ping(from: lan, headers: ["authorization": "Bearer nope"]).status == 401)
        #expect(ping(from: lan, headers: ["authorization": "Bearer \(Self.key)"]).status == 200)
        #expect(ping(from: lan, headers: ["x-api-key": Self.key]).status == 200)
        #expect(ping(from: InternetAddress("fd00::9"), host: "[fd00::1]:8765", headers: ["x-api-key": Self.key]).status == 200)
        #expect(ping(from: InternetAddress("::ffff:192.168.1.50"), headers: ["x-api-key": Self.key]).status == 200)
    }

    @Test func remoteClientsMayUseAnyHostName() {
        let lan = InternetAddress("192.168.1.50")
        #expect(ping(from: lan, host: "my-mac.local:8765", headers: ["x-api-key": Self.key]).status == 200)
    }

    @Test func clientsOutsideAllowedNetworksAreRefusedEvenWithTheKey() {
        #expect(ping(from: InternetAddress("10.0.0.1"), headers: ["x-api-key": Self.key]).status == 403)
        #expect(ping(from: InternetAddress("2001:db8::1"), headers: ["x-api-key": Self.key]).status == 403)
        #expect(ping(from: nil, headers: ["x-api-key": Self.key]).status == 403)
    }

    @Test func loopbackSkipsTheKeyButKeepsHostCheck() {
        #expect(ping(from: .loopbackV4, host: "127.0.0.1:8765").status == 200)
        #expect(ping(from: .loopbackV6, host: "[::1]:8765").status == 200)
        // DNS rebinding to this Mac: loopback peer with a foreign Host.
        #expect(ping(from: .loopbackV4, host: "evil.example.com").status == 403)
        #expect(ping(from: .loopbackV4, host: "evil.example.com", headers: ["x-api-key": Self.key]).status == 403)
    }

    @Test func browserOriginsStayBlockedForRemoteClients() {
        let lan = InternetAddress("192.168.1.50")
        #expect(ping(from: lan, headers: ["x-api-key": Self.key, "origin": "https://evil.example.com"]).status == 403)
        #expect(ping(from: lan, headers: ["x-api-key": Self.key, "origin": "http://localhost:6274"]).status == 200)
    }

    @Test func healthNeedsTheKeyFromOtherMachines() {
        let lan = InternetAddress("192.168.1.50")
        func health(_ headers: [String: String]) -> Int {
            handler.handle(HTTPRequest(method: "GET", path: "/health", headers: ["host": "x"].merging(headers) { $1 }, remoteAddress: lan)).status
        }
        #expect(health([:]) == 401)
        #expect(health(["x-api-key": Self.key]) == 200)
    }

    @Test func localOnlyHandlerRefusesRemoteClients() {
        let local = MCPHTTPHandler(server: MCPServer(name: "t", version: "1", instructions: { "" }))
        let request = HTTPRequest(method: "GET", path: "/health", headers: ["host": "localhost"], remoteAddress: InternetAddress("192.168.1.50"))
        #expect(local.handle(request).status == 403)
        #expect(local.handle(HTTPRequest(method: "GET", path: "/health", headers: ["host": "localhost"], remoteAddress: .loopbackV4)).status == 200)
    }

    @Test func policyChangesApplyToTheNextRequest() {
        let local = MCPHTTPHandler(server: MCPServer(name: "t", version: "1", instructions: { "" }))
        let request = HTTPRequest(method: "GET", path: "/health", headers: ["x-api-key": "k"], remoteAddress: InternetAddress("10.1.1.1"))
        #expect(local.handle(request).status == 403)
        local.accessPolicy = MCPAccessPolicy(allowedNetworks: [CIDRRange("10.0.0.0/8")!], apiKey: "k")
        #expect(local.handle(request).status == 200)
    }
}

struct NetworkAccessConfigTests {
    @Test func oldConfigsWithoutTheNewKeysStayLocalOnly() throws {
        let json = #"{"port": 8765, "mcpServerEnabled": true, "syncRules": []}"#
        let config = try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))
        #expect(config.allowedClientCIDRs.isEmpty)
        #expect(config.apiKey == nil)
        #expect(!config.allowsNetworkClients)
    }

    @Test func roundTripsAndIgnoresInvalidEntries() throws {
        var config = AppConfig()
        config.allowedClientCIDRs = ["192.168.1.0/24", "nonsense", "fd00::/8"]
        config.apiKey = "k"
        let decoded = try JSONDecoder().decode(AppConfig.self, from: JSONEncoder().encode(config))
        #expect(decoded == config)
        #expect(decoded.accessPolicy.allowedNetworks.map(\.description) == ["192.168.1.0/24", "fd00::/8"])

        config.allowedClientCIDRs = ["nonsense"]
        #expect(!config.allowsNetworkClients)
    }

    @Test func storeGeneratesTheKeyWhenNetworkAccessIsTurnedOn() throws {
        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent("eventkit-mcp-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let store = ConfigStore(fileURL: fileURL)
        #expect(store.config.apiKey == nil)

        store.update { $0.allowedClientCIDRs = ["10.0.0.0/8"] }
        let key = try #require(store.config.apiKey)
        #expect(key.hasPrefix("ekmcp_"))
        // Kept when the list changes again or is emptied.
        store.update { $0.allowedClientCIDRs = [] }
        #expect(store.config.apiKey == key)
        let saved = try JSONDecoder().decode(AppConfig.self, from: Data(contentsOf: fileURL))
        #expect(saved.apiKey == key)
    }

    @Test func storeGeneratesTheKeyForHandEditedConfigs() throws {
        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent("eventkit-mcp-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        try Data(#"{"allowedClientCIDRs": ["192.168.0.0/16"]}"#.utf8).write(to: fileURL)
        let store = ConfigStore(fileURL: fileURL)
        let key = try #require(store.config.apiKey)
        #expect(try JSONDecoder().decode(AppConfig.self, from: Data(contentsOf: fileURL)).apiKey == key)
    }
}
