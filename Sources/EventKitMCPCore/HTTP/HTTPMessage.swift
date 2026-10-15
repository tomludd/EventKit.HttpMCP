import Foundation

public struct HTTPRequest: Sendable {
    public var method: String
    public var path: String
    public var version: String
    /// Header names are lower-cased; repeated headers are joined with ", ".
    public var headers: [String: String]
    public var body: Data

    public init(method: String, path: String, version: String = "HTTP/1.1", headers: [String: String] = [:], body: Data = Data()) {
        self.method = method
        self.path = path
        self.version = version
        self.headers = headers
        self.body = body
    }

    public var keepAlive: Bool {
        let connection = headers["connection"]?.lowercased() ?? ""
        if version == "HTTP/1.0" { return connection.contains("keep-alive") }
        return !connection.contains("close")
    }
}

public struct HTTPResponse: Sendable {
    public var status: Int
    public var headers: [(String, String)]
    public var body: Data

    public init(status: Int, headers: [(String, String)] = [], body: Data = Data()) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    public static func json(_ status: Int, _ value: JSONValue, headers: [(String, String)] = []) -> HTTPResponse {
        HTTPResponse(status: status, headers: [("Content-Type", "application/json")] + headers, body: JSONCoding.encode(value))
    }

    public static func text(_ status: Int, _ text: String, headers: [(String, String)] = []) -> HTTPResponse {
        HTTPResponse(status: status, headers: [("Content-Type", "text/plain; charset=utf-8")] + headers, body: Data(text.utf8))
    }

    public func serialized(keepAlive: Bool) -> Data {
        var head = "HTTP/1.1 \(status) \(Self.reason(status))\r\n"
        for (name, value) in headers { head += "\(name): \(value)\r\n" }
        head += "Content-Length: \(body.count)\r\n"
        head += "Cache-Control: no-store\r\n"
        head += "Connection: \(keepAlive ? "keep-alive" : "close")\r\n\r\n"
        var data = Data(head.utf8)
        data.append(body)
        return data
    }

    static func reason(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 202: return "Accepted"
        case 204: return "No Content"
        case 400: return "Bad Request"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 413: return "Payload Too Large"
        case 415: return "Unsupported Media Type"
        case 431: return "Request Header Fields Too Large"
        case 500: return "Internal Server Error"
        case 501: return "Not Implemented"
        default: return "Status"
        }
    }
}

/// Incremental HTTP/1.1 request parser (Content-Length and chunked bodies).
public enum HTTPRequestParser {
    public enum Result {
        case incomplete
        case request(HTTPRequest, consumed: Int)
        case failure(status: Int, message: String)
    }

    public static let maxHeaderBytes = 64 * 1024
    public static let maxBodyBytes = 16 * 1024 * 1024

    public static func parse(_ data: Data) -> Result {
        let bytes = [UInt8](data)
        guard let headerEnd = find([13, 10, 13, 10], in: bytes, from: 0) else {
            return bytes.count > maxHeaderBytes ? .failure(status: 431, message: "Headers too large") : .incomplete
        }
        guard headerEnd <= maxHeaderBytes else { return .failure(status: 431, message: "Headers too large") }

        let headText = String(decoding: bytes[0..<headerEnd], as: UTF8.self)
        var lines = headText.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ", omittingEmptySubsequences: true)
        guard requestLine.count == 3 else { return .failure(status: 400, message: "Malformed request line") }

        var headers: [String: String] = [:]
        for line in lines where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { return .failure(status: 400, message: "Malformed header") }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = headers[name].map { "\($0), \(value)" } ?? value
        }

        var target = String(requestLine[1])
        if let query = target.firstIndex(of: "?") { target = String(target[..<query]) }
        let bodyStart = headerEnd + 4

        let body: [UInt8]
        let consumed: Int
        if headers["transfer-encoding"]?.lowercased().contains("chunked") == true {
            switch decodeChunked(bytes, from: bodyStart) {
            case .incomplete: return .incomplete
            case .failure(let message): return .failure(status: 400, message: message)
            case .done(let decoded, let end):
                body = decoded
                consumed = end
            }
        } else if let lengthText = headers["content-length"] {
            guard let length = Int(lengthText), length >= 0 else {
                return .failure(status: 400, message: "Invalid Content-Length")
            }
            guard length <= maxBodyBytes else { return .failure(status: 413, message: "Body too large") }
            guard bytes.count >= bodyStart + length else { return .incomplete }
            body = Array(bytes[bodyStart..<(bodyStart + length)])
            consumed = bodyStart + length
        } else {
            body = []
            consumed = bodyStart
        }

        let request = HTTPRequest(
            method: String(requestLine[0]).uppercased(),
            path: target,
            version: String(requestLine[2]).uppercased(),
            headers: headers,
            body: Data(body)
        )
        return .request(request, consumed: consumed)
    }

    private enum ChunkResult {
        case incomplete
        case failure(String)
        case done([UInt8], end: Int)
    }

    private static func decodeChunked(_ bytes: [UInt8], from start: Int) -> ChunkResult {
        var cursor = start
        var body: [UInt8] = []
        while true {
            guard let lineEnd = find([13, 10], in: bytes, from: cursor) else { return .incomplete }
            let sizeLine = String(decoding: bytes[cursor..<lineEnd], as: UTF8.self)
            let sizeText = sizeLine.split(separator: ";").first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
            guard let size = Int(sizeText, radix: 16), size >= 0 else { return .failure("Invalid chunk size") }
            cursor = lineEnd + 2
            if size == 0 {
                // Optional trailers, terminated by an empty line.
                if bytes.count >= cursor + 2 && bytes[cursor] == 13 && bytes[cursor + 1] == 10 {
                    return .done(body, end: cursor + 2)
                }
                guard let trailerEnd = find([13, 10, 13, 10], in: bytes, from: cursor) else { return .incomplete }
                return .done(body, end: trailerEnd + 4)
            }
            guard body.count + size <= maxBodyBytes else { return .failure("Body too large") }
            guard bytes.count >= cursor + size + 2 else { return .incomplete }
            body.append(contentsOf: bytes[cursor..<(cursor + size)])
            cursor += size + 2
        }
    }

    private static func find(_ needle: [UInt8], in bytes: [UInt8], from start: Int) -> Int? {
        guard bytes.count >= needle.count, start <= bytes.count - needle.count else { return nil }
        var index = start
        while index <= bytes.count - needle.count {
            if bytes[index] == needle[0] {
                var matched = true
                for offset in 1..<needle.count where bytes[index + offset] != needle[offset] {
                    matched = false
                    break
                }
                if matched { return index }
            }
            index += 1
        }
        return nil
    }
}
