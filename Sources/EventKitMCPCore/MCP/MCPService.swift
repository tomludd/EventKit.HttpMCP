import Foundation

/// Wires the calendar store, sync coordinator and config into an MCP server plus HTTP handler.
public final class MCPService: @unchecked Sendable {
    public static let serverName = "eventkit-http-mcp"

    public let server: MCPServer
    public let httpHandler: MCPHTTPHandler

    public init(store: EventKitCalendarStore, sync: SyncCoordinator, config: ConfigStore, version: String) {
        server = MCPServer(name: Self.serverName, version: version, instructions: CalendarTools.instructions)
        CalendarTools.register(on: server, store: store, sync: sync, config: config)
        httpHandler = MCPHTTPHandler(server: server)
    }

    public static func endpointURL(port: Int) -> String {
        "http://127.0.0.1:\(port)\(MCPHTTPHandler.endpointPath)"
    }

    public static func claudeCodeCommand(port: Int) -> String {
        "claude mcp add --transport http --scope user eventkit \(endpointURL(port: port))"
    }
}
