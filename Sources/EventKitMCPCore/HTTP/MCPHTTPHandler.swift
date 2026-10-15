import Foundation

/// MCP Streamable HTTP transport (stateless, JSON responses only) with local-only access checks.
///
/// - `POST /mcp` carries JSON-RPC messages; requests get `application/json`, notifications get `202`.
/// - `GET /mcp` returns 405: the server never pushes messages, so no SSE stream is offered.
/// - The Host header must name a loopback host (blocks DNS rebinding) and any Origin header must be a
///   loopback origin (blocks web pages in the browser from calling the server).
public final class MCPHTTPHandler: @unchecked Sendable {
    public static let endpointPath = "/mcp"
    private static let loopbackHosts: Set<String> = ["127.0.0.1", "localhost", "::1", "[::1]"]

    private let server: MCPServer

    public init(server: MCPServer) {
        self.server = server
    }

    public func handle(_ request: HTTPRequest) -> HTTPResponse {
        guard Self.isLoopbackHost(request.headers["host"]) else {
            return .json(403, Self.rpcError(-32000, "Forbidden: Host must be localhost/127.0.0.1"))
        }
        if let origin = request.headers["origin"], !Self.isLoopbackOrigin(origin) {
            return .json(403, Self.rpcError(-32000, "Forbidden: cross-origin requests are not allowed"))
        }

        let path = request.path.count > 1 && request.path.hasSuffix("/") ? String(request.path.dropLast()) : request.path
        switch (request.method, path) {
        case ("POST", Self.endpointPath):
            return handlePost(request)
        case (_, Self.endpointPath):
            return .json(405, Self.rpcError(-32000, "Method not allowed"), headers: [("Allow", "POST")])
        case ("GET", "/health"):
            return .json(200, ["status": "ok", "server": .string(server.name), "version": .string(server.version)])
        default:
            return .text(404, "Not found. The MCP endpoint is POST \(Self.endpointPath)")
        }
    }

    private func handlePost(_ request: HTTPRequest) -> HTTPResponse {
        let contentType = request.headers["content-type"]?.lowercased() ?? ""
        guard contentType.contains("application/json") else {
            return .json(415, Self.rpcError(-32000, "Content-Type must be application/json"))
        }
        guard let message = try? JSONDecoder().decode(JSONValue.self, from: request.body) else {
            return .json(400, Self.rpcError(-32700, "Parse error"))
        }

        if case .array(let batch) = message {
            guard !batch.isEmpty else { return .json(400, Self.rpcError(-32600, "Invalid Request")) }
            let responses = batch.compactMap(server.handle)
            return responses.isEmpty ? HTTPResponse(status: 202) : .json(200, .array(responses))
        }
        guard let response = server.handle(message) else { return HTTPResponse(status: 202) }
        return .json(200, response)
    }

    static func rpcError(_ code: Int, _ message: String) -> JSONValue {
        ["jsonrpc": "2.0", "id": nil, "error": ["code": .int(code), "message": .string(message)]]
    }

    static func isLoopbackHost(_ hostHeader: String?) -> Bool {
        guard let hostHeader = hostHeader?.trimmingCharacters(in: .whitespaces).lowercased(), !hostHeader.isEmpty else {
            return false
        }
        let host: String
        if hostHeader.hasPrefix("["), let close = hostHeader.firstIndex(of: "]") {
            host = String(hostHeader[...close])
        } else if hostHeader.filter({ $0 == ":" }).count == 1, let colon = hostHeader.firstIndex(of: ":") {
            host = String(hostHeader[..<colon])
        } else {
            host = hostHeader
        }
        return loopbackHosts.contains(host)
    }

    static func isLoopbackOrigin(_ origin: String) -> Bool {
        guard let components = URLComponents(string: origin.trimmingCharacters(in: .whitespaces)),
              let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = components.host?.lowercased() else {
            return false
        }
        return loopbackHosts.contains(host)
    }
}
