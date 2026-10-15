import Foundation
import Testing
@testable import EventKitMCPCore

struct HTTPRequestParserTests {
    @Test func parsesContentLengthBodyAndLeavesPipelinedBytes() throws {
        let body = #"{"a":1}"#
        let raw = "POST /mcp?x=1 HTTP/1.1\r\nHost: 127.0.0.1:8765\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)GET"
        guard case .request(let request, let consumed) = HTTPRequestParser.parse(Data(raw.utf8)) else {
            Issue.record("expected request")
            return
        }
        #expect(request.method == "POST")
        #expect(request.path == "/mcp")
        #expect(request.headers["content-type"] == "application/json")
        #expect(String(decoding: request.body, as: UTF8.self) == body)
        #expect(consumed == raw.utf8.count - 3)
        #expect(request.keepAlive)
    }

    @Test func waitsForCompleteBody() {
        let raw = "POST /mcp HTTP/1.1\r\nHost: localhost\r\nContent-Length: 10\r\n\r\n12345"
        guard case .incomplete = HTTPRequestParser.parse(Data(raw.utf8)) else {
            Issue.record("expected incomplete")
            return
        }
    }

    @Test func decodesChunkedBody() {
        let raw = "POST /mcp HTTP/1.1\r\nHost: localhost\r\nTransfer-Encoding: chunked\r\n\r\n4\r\n{\"a\"\r\n3\r\n:1}\r\n0\r\n\r\n"
        guard case .request(let request, let consumed) = HTTPRequestParser.parse(Data(raw.utf8)) else {
            Issue.record("expected request")
            return
        }
        #expect(String(decoding: request.body, as: UTF8.self) == #"{"a":1}"#)
        #expect(consumed == raw.utf8.count)
    }

    @Test func rejectsMalformedRequestLine() {
        guard case .failure(let status, _) = HTTPRequestParser.parse(Data("GARBAGE\r\n\r\n".utf8)) else {
            Issue.record("expected failure")
            return
        }
        #expect(status == 400)
    }
}

struct MCPHTTPHandlerTests {
    let handler: MCPHTTPHandler = {
        let server = MCPServer(name: "test", version: "1.0", instructions: { "hello" })
        server.register(MCPTool(name: "echo", title: "Echo", description: "Echoes", inputSchema: ["type": "object"], readOnly: true) { args in
            ["text": try args.requiredString("text")]
        })
        server.register(MCPTool(name: "fail", title: "Fail", description: "Fails", inputSchema: ["type": "object"], readOnly: true) { _ in
            throw ToolError("boom")
        })
        return MCPHTTPHandler(server: server)
    }()

    func post(_ json: String, host: String = "127.0.0.1:8765", origin: String? = nil, contentType: String = "application/json") -> HTTPResponse {
        var headers = ["host": host, "content-type": contentType, "accept": "application/json, text/event-stream"]
        headers["origin"] = origin
        return handler.handle(HTTPRequest(method: "POST", path: "/mcp", headers: headers, body: Data(json.utf8)))
    }

    func decode(_ response: HTTPResponse) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: response.body)
    }

    @Test func initializeNegotiatesProtocolVersion() throws {
        let response = post(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"t","version":"1"}}}"#)
        #expect(response.status == 200)
        let body = try decode(response)
        #expect(body["id"] == 1)
        #expect(body["result"]?["protocolVersion"] == "2025-06-18")
        #expect(body["result"]?["capabilities"]?["tools"] != nil)
        #expect(body["result"]?["instructions"] == "hello")

        let unknown = try decode(post(#"{"jsonrpc":"2.0","id":2,"method":"initialize","params":{"protocolVersion":"1999-01-01"}}"#))
        #expect(unknown["result"]?["protocolVersion"]?.stringValue == MCPServer.supportedProtocolVersions[0])
    }

    @Test func notificationsGet202() {
        let response = post(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)
        #expect(response.status == 202)
        #expect(response.body.isEmpty)
    }

    @Test func listsAndCallsTools() throws {
        let list = try decode(post(#"{"jsonrpc":"2.0","id":"a","method":"tools/list"}"#))
        let tools = try #require(list["result"]?["tools"]?.arrayValue)
        #expect(tools.compactMap { $0["name"]?.stringValue } == ["echo", "fail"])
        #expect(tools[0]["annotations"]?["readOnlyHint"] == true)

        let call = try decode(post(#"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"echo","arguments":{"text":"hi"}}}"#))
        #expect(call["result"]?["isError"] == false)
        let text = try #require(call["result"]?["content"]?.arrayValue?.first?["text"]?.stringValue)
        #expect(text.contains(#""text" : "hi""#))
    }

    @Test func toolErrorsAreReportedInResult() throws {
        let call = try decode(post(#"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"fail"}}"#))
        #expect(call["result"]?["isError"] == true)
        #expect(call["result"]?["content"]?.arrayValue?.first?["text"] == "Error: boom")

        let unknown = try decode(post(#"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"nope"}}"#))
        #expect(unknown["error"]?["code"] == -32602)
    }

    @Test func unknownMethodAndParseErrors() throws {
        let unknown = try decode(post(#"{"jsonrpc":"2.0","id":6,"method":"resources/list"}"#))
        #expect(unknown["error"]?["code"] == -32601)
        let parse = post("{not json")
        #expect(parse.status == 400)
        #expect(try decode(parse)["error"]?["code"] == -32700)
    }

    @Test func batchesAreSupported() throws {
        let response = post(#"[{"jsonrpc":"2.0","id":1,"method":"ping"},{"jsonrpc":"2.0","method":"notifications/initialized"}]"#)
        #expect(response.status == 200)
        #expect(try decode(response).arrayValue?.count == 1)
    }

    @Test func rejectsNonLocalHostHeader() {
        #expect(post(#"{"jsonrpc":"2.0","id":1,"method":"ping"}"#, host: "evil.example.com").status == 403)
        #expect(post(#"{"jsonrpc":"2.0","id":1,"method":"ping"}"#, host: "192.168.1.10:8765").status == 403)
        #expect(post(#"{"jsonrpc":"2.0","id":1,"method":"ping"}"#, host: "localhost:8765").status == 200)
        #expect(post(#"{"jsonrpc":"2.0","id":1,"method":"ping"}"#, host: "[::1]:8765").status == 200)
    }

    @Test func rejectsBrowserOriginsThatAreNotLocal() {
        #expect(post(#"{"jsonrpc":"2.0","id":1,"method":"ping"}"#, origin: "https://evil.example.com").status == 403)
        #expect(post(#"{"jsonrpc":"2.0","id":1,"method":"ping"}"#, origin: "null").status == 403)
        #expect(post(#"{"jsonrpc":"2.0","id":1,"method":"ping"}"#, origin: "http://localhost:6274").status == 200)
    }

    @Test func requiresJSONContentTypeAndPost() {
        #expect(post(#"{"jsonrpc":"2.0","id":1,"method":"ping"}"#, contentType: "text/plain").status == 415)
        let get = handler.handle(HTTPRequest(method: "GET", path: "/mcp", headers: ["host": "127.0.0.1"]))
        #expect(get.status == 405)
        let other = handler.handle(HTTPRequest(method: "GET", path: "/other", headers: ["host": "127.0.0.1"]))
        #expect(other.status == 404)
    }
}
