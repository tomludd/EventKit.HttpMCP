import Darwin
import Foundation
import Network

/// An IPv4 or IPv6 address as network-order bytes. IPv4-mapped IPv6 addresses (`::ffff:a.b.c.d`) are
/// stored as the IPv4 address they carry, so a dual-stack listener's peers match IPv4 networks.
public struct InternetAddress: Hashable, Sendable, CustomStringConvertible {
    /// 4 bytes for IPv4, 16 for IPv6.
    public let bytes: [UInt8]

    public static let loopbackV4 = InternetAddress(bytes: [127, 0, 0, 1])!
    public static let loopbackV6 = InternetAddress(bytes: [UInt8](repeating: 0, count: 15) + [1])!

    public init?(bytes: [UInt8]) {
        switch bytes.count {
        case 4:
            self.bytes = bytes
        case 16:
            let isMapped = bytes[0..<10].allSatisfy { $0 == 0 } && bytes[10] == 0xff && bytes[11] == 0xff
            self.bytes = isMapped ? Array(bytes[12...]) : bytes
        default:
            return nil
        }
    }

    /// Parses a literal address (`192.168.1.5`, `fd00::1`, `::ffff:10.0.0.1`). No zone ids, ports or brackets.
    public init?(_ string: String) {
        let text = string.trimmingCharacters(in: .whitespaces)
        // Darwin's inet_pton accepts zone ids ("fe80::1%en0") and embeds them in the address bytes.
        guard !text.isEmpty, !text.contains("%") else { return nil }
        if text.contains(":") {
            var address = in6_addr()
            guard inet_pton(AF_INET6, text, &address) == 1 else { return nil }
            self.init(bytes: withUnsafeBytes(of: &address) { Array($0) })
        } else {
            var address = in_addr()
            guard inet_pton(AF_INET, text, &address) == 1 else { return nil }
            self.init(bytes: withUnsafeBytes(of: &address) { Array($0) })
        }
    }

    /// The address of a connection's remote endpoint; nil for names other than `localhost`.
    public init?(host: NWEndpoint.Host) {
        switch host {
        case .ipv4(let address): self.init(bytes: [UInt8](address.rawValue))
        case .ipv6(let address): self.init(bytes: [UInt8](address.rawValue))
        case .name(let name, _):
            guard name.lowercased() == "localhost" else { return nil }
            self = .loopbackV4
        @unknown default: return nil
        }
    }

    public init?(endpoint: NWEndpoint) {
        guard case .hostPort(let host, _) = endpoint else { return nil }
        self.init(host: host)
    }

    public var isIPv4: Bool { bytes.count == 4 }

    /// 127.0.0.0/8 or ::1.
    public var isLoopback: Bool {
        isIPv4 ? bytes[0] == 127 : self == .loopbackV6
    }

    public var description: String {
        if isIPv4 { return bytes.map(String.init).joined(separator: ".") }
        var address = in6_addr()
        withUnsafeMutableBytes(of: &address) { $0.copyBytes(from: bytes) }
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        guard inet_ntop(AF_INET6, &address, &buffer, socklen_t(buffer.count)) != nil else { return "?" }
        return String(cString: buffer)
    }

    /// Non-loopback, non-link-local addresses of this Mac's active interfaces, IPv4 first.
    public static func localInterfaceAddresses() -> [InternetAddress] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }
        var result: [InternetAddress] = []
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            guard entry.ifa_flags & UInt32(IFF_UP) != 0, entry.ifa_flags & UInt32(IFF_LOOPBACK) == 0,
                  let socketAddress = entry.ifa_addr else { continue }
            let address: InternetAddress?
            switch Int32(socketAddress.pointee.sa_family) {
            case AF_INET:
                address = socketAddress.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { pointer in
                    var raw = pointer.pointee.sin_addr
                    return InternetAddress(bytes: withUnsafeBytes(of: &raw) { Array($0) })
                }
            case AF_INET6:
                address = socketAddress.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { pointer in
                    var raw = pointer.pointee.sin6_addr
                    return InternetAddress(bytes: withUnsafeBytes(of: &raw) { Array($0) })
                }
            default:
                address = nil
            }
            guard let address, !address.isLoopback, !address.isLinkLocal, !result.contains(address) else { continue }
            result.append(address)
        }
        return result.filter(\.isIPv4) + result.filter { !$0.isIPv4 }
    }

    /// 169.254.0.0/16 or fe80::/10.
    var isLinkLocal: Bool {
        isIPv4 ? bytes[0] == 169 && bytes[1] == 254 : bytes[0] == 0xfe && bytes[1] & 0xc0 == 0x80
    }
}

/// A network in CIDR notation (`192.168.1.0/24`, `fd00::/8`). A bare address is a single host
/// (/32 or /128). IPv4-mapped IPv6 networks (`::ffff:10.0.0.0/104`) are stored as IPv4 networks.
public struct CIDRRange: Hashable, Sendable, CustomStringConvertible {
    /// The network address, host bits cleared.
    public let network: InternetAddress
    public let prefixLength: Int

    public init?(_ string: String) {
        let text = string.trimmingCharacters(in: .whitespaces)
        let parts = text.split(separator: "/", omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count), let address = InternetAddress(String(parts[0])) else { return nil }
        let writtenAsIPv6 = parts[0].contains(":")
        let writtenBits = writtenAsIPv6 ? 128 : 32

        var prefix = writtenBits
        if parts.count == 2 {
            let digits = parts[1]
            guard !digits.isEmpty, digits.count <= 3, digits.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let value = Int(digits), value <= writtenBits else { return nil }
            prefix = value
        }
        if writtenAsIPv6 && address.isIPv4 {
            // An IPv4-mapped network; a shorter prefix would also cover non-mapped IPv6 space.
            guard prefix >= 96 else { return nil }
            prefix -= 96
        }
        self.network = InternetAddress(bytes: Self.masked(address.bytes, prefix: prefix))!
        self.prefixLength = prefix
    }

    public func contains(_ address: InternetAddress) -> Bool {
        address.isIPv4 == network.isIPv4 && Self.masked(address.bytes, prefix: prefixLength) == network.bytes
    }

    /// Covers every address of its family (`0.0.0.0/0` or `::/0`).
    public var matchesEverything: Bool { prefixLength == 0 }

    public var description: String { "\(network)/\(prefixLength)" }

    static func masked(_ bytes: [UInt8], prefix: Int) -> [UInt8] {
        bytes.enumerated().map { index, byte in
            let bits = min(max(prefix - index * 8, 0), 8)
            return bits == 8 ? byte : byte & ~(UInt8(0xff) >> bits)
        }
    }
}
