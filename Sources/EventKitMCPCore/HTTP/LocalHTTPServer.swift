import Foundation
import Network

/// Minimal HTTP/1.1 server. With a local-only access policy it binds to the loopback interfaces only
/// (127.0.0.1 and ::1); with allowed networks it listens on all interfaces. Either way, connections from
/// addresses the policy does not allow are dropped before any request is read.
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
    private var policy: MCPAccessPolicy
    /// Whether the listeners were started on all interfaces; fixed until the server is restarted.
    public let listensOnNetwork: Bool

    /// Called on the server's queue whenever the status changes.
    public var onStatusChange: ((Status) -> Void)?

    public init(port: UInt16, accessPolicy: MCPAccessPolicy = .localOnly, handler: @escaping (HTTPRequest) -> HTTPResponse) {
        self.port = port
        self.policy = accessPolicy
        self.listensOnNetwork = accessPolicy.allowsNetworkClients
        self.handler = handler
    }

    public var status: Status { queue.sync { currentStatus } }

    /// Applies to new connections. A change of `allowsNetworkClients` needs a restart to rebind.
    public var accessPolicy: MCPAccessPolicy {
        get { queue.sync { policy } }
        set { queue.async { [self] in policy = newValue } }
    }

    public func start() {
        queue.async { [self] in
            guard listeners.isEmpty else { return }
            guard let nwPort = NWEndpoint.Port(rawValue: port), port != 0 else {
                setStatus(.failed("Invalid port \(port)"))
                return
            }
            setStatus(.starting)
            // nil host: one dual-stack listener on all interfaces.
            let hosts: [(String?, Bool)] = listensOnNetwork ? [(nil, true)] : [("127.0.0.1", true), ("::1", false)]
            for (host, isPrimary) in hosts {
                let hostName = host ?? "*"
                do {
                    let parameters = NWParameters.tcp
                    parameters.allowLocalEndpointReuse = true
                    let listener: NWListener
                    if let host {
                        parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(host), port: nwPort)
                        listener = try NWListener(using: parameters)
                    } else {
                        listener = try NWListener(using: parameters, on: nwPort)
                    }
                    listener.stateUpdateHandler = { [weak self] state in
                        self?.listener(host: hostName, isPrimary: isPrimary, changedTo: state)
                    }
                    listener.newConnectionHandler = { [weak self] connection in
                        self?.accept(connection)
                    }
                    listener.start(queue: queue)
                    listeners.append(listener)
                } catch {
                    if isPrimary { setStatus(.failed(error.localizedDescription)) }
                    NSLog("EventKitMCP: could not listen on \(hostName):\(port): \(error)")
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
        let address = InternetAddress(endpoint: connection.endpoint)
        guard policy.allowsConnection(from: address) else {
            NSLog("EventKitMCP: refused connection from \(connection.endpoint)")
            connection.cancel()
            return
        }
        let http = HTTPConnection(connection: connection, remoteAddress: address, handler: handler)
        let key = ObjectIdentifier(http)
        connections[key] = http
        http.onClose = { [weak self] in
            self?.queue.async { self?.connections[key] = nil }
        }
        http.start()
    }
}

/// One keep-alive TCP connection. Requests are handled in order on the connection's own queue,
/// so a slow tool call (e.g. a sync run) does not block other clients.
final class HTTPConnection: @unchecked Sendable {
    private let connection: NWConnection
    private let remoteAddress: InternetAddress?
    private let handler: (HTTPRequest) -> HTTPResponse
    private let queue = DispatchQueue(label: "eventkit-mcp.http.connection", target: .global(qos: .userInitiated))
    private var buffer = Data()
    /// No further requests are processed (a `Connection: close` response may still be in flight).
    private var closed = false
    private var cancelled = false
    var onClose: (() -> Void)?

    init(connection: NWConnection, remoteAddress: InternetAddress?, handler: @escaping (HTTPRequest) -> HTTPResponse) {
        self.connection = connection
        self.remoteAddress = remoteAddress
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
            case .request(var request, let consumed):
                buffer = buffer.subdata(in: consumed..<buffer.count)
                request.remoteAddress = remoteAddress
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
