import Foundation

public struct ToolError: LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

public struct MCPTool {
    public let name: String
    public let title: String
    public let description: String
    public let inputSchema: JSONValue
    public let readOnly: Bool
    public let destructive: Bool
    public let handler: (ToolArguments) throws -> any Encodable

    public init(
        name: String, title: String, description: String, inputSchema: JSONValue, readOnly: Bool,
        destructive: Bool = false, handler: @escaping (ToolArguments) throws -> any Encodable
    ) {
        self.name = name
        self.title = title
        self.description = description
        self.inputSchema = inputSchema
        self.readOnly = readOnly
        self.destructive = destructive
        self.handler = handler
    }

    var definition: JSONValue {
        [
            "name": .string(name),
            "title": .string(title),
            "description": .string(description),
            "inputSchema": inputSchema,
            "annotations": [
                "title": .string(title),
                "readOnlyHint": .bool(readOnly),
                "destructiveHint": .bool(destructive),
                "openWorldHint": false,
            ],
        ]
    }
}

/// JSON-RPC 2.0 / Model Context Protocol message handling (transport independent).
public final class MCPServer: @unchecked Sendable {
    public static let supportedProtocolVersions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]

    public let name: String
    public let version: String
    private let instructions: () -> String
    private var tools: [MCPTool] = []

    public init(name: String, version: String, instructions: @escaping () -> String) {
        self.name = name
        self.version = version
        self.instructions = instructions
    }

    public func register(_ tool: MCPTool) {
        tools.append(tool)
    }

    public var toolNames: [String] { tools.map(\.name) }

    /// Handles one JSON-RPC message. Returns nil for notifications and responses (nothing to send back).
    public func handle(_ message: JSONValue) -> JSONValue? {
        guard case .object(let object) = message else {
            return Self.error(id: .null, code: -32600, message: "Invalid Request")
        }
        guard let method = object["method"]?.stringValue else {
            return nil // A response from the client (we never send requests) — ignore.
        }
        guard let id = object["id"], !id.isNull else {
            return nil // Notification, e.g. notifications/initialized.
        }
        let params = object["params"] ?? .object([:])

        switch method {
        case "initialize":
            return Self.result(id: id, initialize(params))
        case "ping":
            return Self.result(id: id, .object([:]))
        case "tools/list":
            return Self.result(id: id, ["tools": .array(tools.map(\.definition))])
        case "tools/call":
            return callTool(id: id, params: params)
        default:
            return Self.error(id: id, code: -32601, message: "Method not found: \(method)")
        }
    }

    private func initialize(_ params: JSONValue) -> JSONValue {
        let requested = params["protocolVersion"]?.stringValue ?? ""
        let protocolVersion = Self.supportedProtocolVersions.contains(requested) ? requested : Self.supportedProtocolVersions[0]
        return [
            "protocolVersion": .string(protocolVersion),
            "capabilities": ["tools": ["listChanged": false]],
            "serverInfo": ["name": .string(name), "title": "EventKit MCP", "version": .string(version)],
            "instructions": .string(instructions()),
        ]
    }

    private func callTool(id: JSONValue, params: JSONValue) -> JSONValue {
        guard let toolName = params["name"]?.stringValue else {
            return Self.error(id: id, code: -32602, message: "Missing tool name")
        }
        guard let tool = tools.first(where: { $0.name == toolName }) else {
            return Self.error(id: id, code: -32602, message: "Unknown tool: \(toolName)")
        }
        let arguments = ToolArguments(params["arguments"]?.objectValue ?? [:])
        do {
            let output = try tool.handler(arguments)
            let data = try JSONCoding.prettyEncoder().encode(output)
            return Self.result(id: id, Self.toolResult(text: String(decoding: data, as: UTF8.self), isError: false))
        } catch {
            return Self.result(id: id, Self.toolResult(text: "Error: \(error.localizedDescription)", isError: true))
        }
    }

    static func toolResult(text: String, isError: Bool) -> JSONValue {
        ["content": [["type": "text", "text": .string(text)]], "isError": .bool(isError)]
    }

    static func result(id: JSONValue, _ result: JSONValue) -> JSONValue {
        ["jsonrpc": "2.0", "id": id, "result": result]
    }

    static func error(id: JSONValue, code: Int, message: String) -> JSONValue {
        ["jsonrpc": "2.0", "id": id, "error": ["code": .int(code), "message": .string(message)]]
    }
}

/// Typed accessors for tool arguments.
public struct ToolArguments {
    public let raw: [String: JSONValue]

    public init(_ raw: [String: JSONValue]) {
        self.raw = raw
    }

    public func has(_ key: String) -> Bool {
        guard let value = raw[key] else { return false }
        return !value.isNull
    }

    public func string(_ key: String) -> String? {
        guard let value = raw[key]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }

    public func requiredString(_ key: String) throws -> String {
        guard let value = string(key) else { throw ToolError("Missing required argument `\(key)`.") }
        return value
    }

    /// For updates: nil = not provided, .some(nil) = clear the field, .some(value) = set it.
    public func clearableString(_ key: String) -> String?? {
        guard let value = raw[key] else { return nil }
        if value.isNull { return .some(nil) }
        guard let text = value.stringValue else { return nil }
        return .some(text.isEmpty ? nil : text)
    }

    public func int(_ key: String) throws -> Int? {
        guard has(key) else { return nil }
        guard let value = raw[key]?.intValue else { throw ToolError("`\(key)` must be an integer.") }
        return value
    }

    public func bool(_ key: String) throws -> Bool? {
        guard has(key) else { return nil }
        guard let value = raw[key]?.boolValue else { throw ToolError("`\(key)` must be a boolean.") }
        return value
    }

    /// Accepts a JSON array of strings or a comma-separated string.
    public func stringArray(_ key: String) -> [String]? {
        guard let value = raw[key] else { return nil }
        let items: [String]
        if let array = value.arrayValue {
            items = array.compactMap(\.stringValue)
        } else if let text = value.stringValue {
            items = text.split(separator: ",").map(String.init)
        } else {
            return nil
        }
        let trimmed = items.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return trimmed.isEmpty ? nil : trimmed
    }

    public func intArray(_ key: String) throws -> [Int]? {
        guard let value = raw[key], !value.isNull else { return nil }
        guard let array = value.arrayValue else { throw ToolError("`\(key)` must be an array of integers.") }
        return try array.map { item in
            guard let number = item.intValue else { throw ToolError("`\(key)` must be an array of integers.") }
            return number
        }
    }

    public func date(_ key: String, endOfDayIfDateOnly: Bool = false, now: Date = Date()) throws -> Date? {
        guard let text = string(key) else { return nil }
        guard let date = DateInput.parse(text, now: now, endOfDayIfDateOnly: endOfDayIfDateOnly) else {
            throw ToolError("Could not parse `\(key)`: '\(text)'. Use ISO 8601 (2026-10-15T14:00:00+02:00), 'YYYY-MM-DD HH:mm', 'YYYY-MM-DD' or today/tomorrow/now.")
        }
        return date
    }

    public func object(_ key: String) -> ToolArguments? {
        raw[key]?.objectValue.map(ToolArguments.init)
    }
}
