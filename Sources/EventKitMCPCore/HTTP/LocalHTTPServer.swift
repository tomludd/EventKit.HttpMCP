import Foundation
import Network

/// Minimal HTTP/1.1 server bound to the loopback interfaces only (127.0.0.1 and ::1).
/// Connections whose remote address is not loopback are dropped as a second line of defence.
public final class LocalHTTPServer: @unchecked Sendable {
    public enum Status: Equatable, Sendable {
        case stopped
        case starting
        case running(port: UInt16)
        case failed(String)
    }

    public let port: UInt16
    private let handler: (HTTPRequest) -> HTTPResponse
    private let queue = DispatchQueue(label: "eventkit-mcp.http")
    private var listeners: [NWListener] = []
    private var connections: [ObjectIdentifier: HTTPConnection] = [:]
    private var currentStatus: Status = .stopped

    /// Called on the server's queue whenever the status changes.
    public var onStatusChange: ((Status) -> Void)?

    public init(port: UInt16, handler: @escaping (HTTPRequest) -> HTTPResponse) {
        self.port = port
        self.handler = handler
    }

    public var status: Status { queue.sync { currentStatus } }

    public func start() {
        queue.async { [self] in
            guard listeners.isEmpty else { return }
            guard let nwPort = NWEndpoint.Port(rawValue: port), port != 0 else {
                setStatus(.failed("Invalid port \(port)"))
                return
            }
            setStatus(.starting)
            for (host, isPrimary) in [("127.0.0.1", true), ("::1", false)] {
                do {
                    let parameters = NWParameters.tcp
                    parameters.allowLocalEndpointReuse = true
                    parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(host), port: nwPort)
                    let listener = try NWListener(using: parameters)
                    listener.stateUpdateHandler = { [weak self] state in
                        self?.listener(host: host, isPrimary: isPrimary, changedTo: state)
                    }
                    listener.newConnectionHandler = { [weak self] connection in
                        self?.accept(connection)
                    }
                    listener.start(queue: queue)
                    listeners.append(listener)
                } catch {
                    if isPrimary { setStatus(.failed(error.localizedDescription)) }
                    NSLog("EventKitMCP: could not listen on \(host):\(port): \(error)")
                }
            }
        }
    }

    public func stop() {
        queue.sync {
            listeners.forEach { $0.cancel() }
            listeners.removeAll()
            connections.values.forEach { $0.close() }
            connections.removeAll()
            setStatus(.stopped)
        }
    }

    private func listener(host: String, isPrimary: Bool, changedTo state: NWListener.State) {
        switch state {
        case .ready:
            if isPrimary { setStatus(.running(port: port)) }
        case .failed(let error):
            NSLog("EventKitMCP: listener \(host):\(port) failed: \(error)")
            if isPrimary {
                let message: String
                if case .posix(let code) = error, code == .EADDRINUSE {
                    message = "Port \(port) is already in use"
                } else {
                    message = error.localizedDescription
                }
                setStatus(.failed(message))
            }
        default:
            break
        }
    }

    private func setStatus(_ status: Status) {
        guard status != currentStatus else { return }
        currentStatus = status
        onStatusChange?(status)
    }

    private func accept(_ connection: NWConnection) {
        guard Self.isLoopback(connection.endpoint) else {
            NSLog("EventKitMCP: rejected non-loopback connection from \(connection.endpoint)")
            connection.cancel()
            return
        }
        let http = HTTPConnection(connection: connection, handler: handler)
        let key = ObjectIdentifier(http)
        connections[key] = http
        http.onClose = { [weak self] in
            self?.queue.async { self?.connections[key] = nil }
        }
        http.start()
    }

    static func isLoopback(_ endpoint: NWEndpoint) -> Bool {
        guard case .hostPort(let host, _) = endpoint else { return false }
        switch host {
        case .ipv4(let address):
            return address.isLoopback
        case .ipv6(let address):
            if address.isLoopback { return true }
            if let mapped = address.asIPv4 { return mapped.isLoopback }
            return false
        case .name(let name, _):
            return name == "localhost"
        @unknown default:
            return false
        }
    }
}

/// One keep-alive TCP connection. Requests are handled in order on the connection's own queue,
/// so a slow tool call (e.g. a sync run) does not block other clients.
final class HTTPConnection: @unchecked Sendable {
    private let connection: NWConnection
    private let handler: (HTTPRequest) -> HTTPResponse
    private let queue = DispatchQueue(label: "eventkit-mcp.http.connection", target: .global(qos: .userInitiated))
    private var buffer = Data()
    /// No further requests are processed (a `Connection: close` response may still be in flight).
    private var closed = false
    private var cancelled = false
    var onClose: (() -> Void)?

    init(connection: NWConnection, handler: @escaping (HTTPRequest) -> HTTPResponse) {
        self.connection = connection
        self.handler = handler
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.close()
            default: break
            }
        }
        connection.start(queue: queue)
        receive()
    }

    func close() {
        queue.async { [self] in
            guard !cancelled else { return }
            cancelled = true
            closed = true
            connection.cancel()
            onClose?()
            onClose = nil
        }
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                buffer.append(data)
                process()
            }
            if isComplete || error != nil {
                close()
            } else if !closed {
                receive()
            }
        }
    }

    private func process() {
        while !closed {
            switch HTTPRequestParser.parse(buffer) {
            case .incomplete:
                return
            case .failure(let status, let message):
                send(.text(status, message), keepAlive: false)
                return
            case .request(let request, let consumed):
                buffer = buffer.subdata(in: consumed..<buffer.count)
                let response = handler(request)
                send(response, keepAlive: request.keepAlive)
            }
        }
    }

    private func send(_ response: HTTPResponse, keepAlive: Bool) {
        if !keepAlive { closed = true }
        connection.send(content: response.serialized(keepAlive: keepAlive), completion: .contentProcessed { [weak self] _ in
            if !keepAlive { self?.close() }
        })
    }
}
