import Darwin
import Foundation

/// Network boundary for model-directed browsing. Validation is repeated for
/// every top-level navigation so redirects cannot pivot from a public URL into
/// localhost, a private tailnet/LAN host, or a metadata endpoint.
enum WebURLPolicy {
    /// User-configured service endpoints may use cleartext only when DNS and
    /// literals remain entirely inside loopback/private/link-local/tailnet
    /// space. Public endpoints must use HTTPS. Credentials in URLs are always
    /// refused so secrets do not leak through logs or configuration exports.
    static func permitsUserConfiguredService(_ url: URL, resolveDNS: Bool = true) -> Bool {
        guard url.user == nil, url.password == nil,
              let scheme = url.scheme?.lowercased(),
              let host = url.host, !host.isEmpty else { return false }
        guard !isForbiddenServiceIPAddress(host) else { return false }
        if scheme == "https" { return true }
        guard scheme == "http" else { return false }
        let normalizedHost = host.lowercased()
        if isBlockedHostname(host) || normalizedHost.hasSuffix(".ts.net")
            || isPrivateIPAddress(host) { return true }
        guard resolveDNS else { return false }
        let addresses = resolvedNumericAddresses(host)
        return !addresses.isEmpty && addresses.allSatisfy {
            isPrivateIPAddress($0) && !isForbiddenServiceIPAddress($0)
        }
    }

    /// User-configured service credentials and request bodies must never follow
    /// a redirect to a different origin. ATS is intentionally broad enough for
    /// private HTTP/tailnet endpoints, so this application-layer check is the
    /// boundary that prevents a configured server from pivoting to public HTTP
    /// or another host/port.
    static func permitsUserConfiguredServiceRedirect(
        from source: URL,
        to destination: URL,
        resolveDNS: Bool = true
    ) -> Bool {
        guard permitsUserConfiguredService(source, resolveDNS: resolveDNS),
              permitsUserConfiguredService(destination, resolveDNS: resolveDNS),
              source.scheme?.lowercased() == destination.scheme?.lowercased(),
              source.host?.lowercased() == destination.host?.lowercased(),
              effectivePort(source) == effectivePort(destination) else { return false }
        return true
    }

    static func rejectionReason(for url: URL, resolveDNS: Bool = true) -> String? {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return "only http(s) URLs are allowed"
        }
        guard url.user == nil, url.password == nil else { return "URLs containing credentials are refused" }
        guard let host = url.host, !host.isEmpty else { return "URL has no host" }
        if isBlockedHostname(host) { return "private, loopback, link-local, or internal host" }
        if isPrivateIPAddress(host) { return "private, loopback, link-local, or reserved IP address" }
        if resolveDNS {
            let addresses = resolvedNumericAddresses(host)
            if addresses.isEmpty { return "host could not be resolved" }
            if addresses.contains(where: isPrivateIPAddress) {
                return "host resolves to a private, loopback, link-local, or reserved address"
            }
        }
        return nil
    }

    static func isBlockedHostname(_ host: String) -> Bool {
        let h = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        return h == "localhost" || h.hasSuffix(".localhost") || h.hasSuffix(".local") ||
            h.hasSuffix(".internal") || h.hasSuffix(".home") || h.hasSuffix(".lan")
    }

    static func isPrivateIPAddress(_ raw: String) -> Bool {
        let host = raw.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        var ipv4 = in_addr()
        if inet_pton(AF_INET, host, &ipv4) == 1 {
            let value = UInt32(bigEndian: ipv4.s_addr)
            let first = UInt8((value >> 24) & 0xff)
            let second = UInt8((value >> 16) & 0xff)
            if first == 0 || first == 10 || first == 127 { return true }
            if first == 100, (64...127).contains(second) { return true } // carrier-grade NAT / tailnets
            if first == 169, second == 254 { return true }
            if first == 172, (16...31).contains(second) { return true }
            if first == 192, second == 168 { return true }
            if first >= 224 { return true } // multicast + reserved
            return false
        }

        var ipv6 = in6_addr()
        if inet_pton(AF_INET6, host, &ipv6) == 1 {
            let bytes = withUnsafeBytes(of: &ipv6) { Array($0) }
            if bytes.allSatisfy({ $0 == 0 }) { return true }
            if bytes.dropLast().allSatisfy({ $0 == 0 }), bytes.last == 1 { return true }
            if bytes[0] == 0xfc || bytes[0] == 0xfd { return true }
            if bytes[0] == 0xfe, (bytes[1] & 0xc0) == 0x80 { return true }
            if bytes[0] == 0xff { return true }
            // IPv4-mapped IPv6 (::ffff:a.b.c.d).
            if bytes[0..<10].allSatisfy({ $0 == 0 }), bytes[10] == 0xff, bytes[11] == 0xff {
                return isPrivateIPAddress("\(bytes[12]).\(bytes[13]).\(bytes[14]).\(bytes[15])")
            }
            return false
        }
        return false
    }

    /// Link-local metadata, unspecified, multicast and reserved literals are
    /// never valid service endpoints, even when the broad ATS exception allows
    /// the socket. This check runs before every user-configured request.
    static func isForbiddenServiceIPAddress(_ raw: String) -> Bool {
        let host = raw.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        var ipv4 = in_addr()
        if inet_pton(AF_INET, host, &ipv4) == 1 {
            let value = UInt32(bigEndian: ipv4.s_addr)
            let first = UInt8((value >> 24) & 0xff)
            let second = UInt8((value >> 16) & 0xff)
            return first == 0 || (first == 169 && second == 254) || first >= 224
        }
        var ipv6 = in6_addr()
        if inet_pton(AF_INET6, host, &ipv6) == 1 {
            let bytes = withUnsafeBytes(of: &ipv6) { Array($0) }
            if bytes.allSatisfy({ $0 == 0 }) { return true }
            if bytes[0] == 0xfe, (bytes[1] & 0xc0) == 0x80 { return true }
            if bytes[0] == 0xff { return true }
            if bytes[0..<10].allSatisfy({ $0 == 0 }), bytes[10] == 0xff, bytes[11] == 0xff {
                return isForbiddenServiceIPAddress(
                    "\(bytes[12]).\(bytes[13]).\(bytes[14]).\(bytes[15])"
                )
            }
        }
        return false
    }

    private static func resolvedNumericAddresses(_ host: String) -> [String] {
        var hints = addrinfo()
        hints.ai_flags = AI_ADDRCONFIG
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &result) == 0, let first = result else { return [] }
        defer { freeaddrinfo(first) }
        var addresses: [String] = []
        var cursor: UnsafeMutablePointer<addrinfo>? = first
        while let info = cursor?.pointee {
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(info.ai_addr, info.ai_addrlen, &buffer, socklen_t(buffer.count), nil, 0,
                           NI_NUMERICHOST) == 0 {
                let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
                addresses.append(String(decoding: bytes, as: UTF8.self))
            }
            cursor = info.ai_next
        }
        return addresses
    }

    private static func effectivePort(_ url: URL) -> Int? {
        if let port = url.port { return port }
        switch url.scheme?.lowercased() {
        case "http": return 80
        case "https": return 443
        default: return nil
        }
    }
}

/// A cookie-free session for endpoints selected by the user. Every redirect is
/// re-authorized and remains same-origin, including the effective port.
final class UserConfiguredServiceRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        guard let source = response.url ?? task.currentRequest?.url ?? task.originalRequest?.url,
              let destination = request.url,
              WebURLPolicy.permitsUserConfiguredServiceRedirect(
                from: source,
                to: destination,
                resolveDNS: false
              ) else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}

enum UserConfiguredServiceSession {
    static let shared = make()

    static func make(timeout: TimeInterval = 60) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        return URLSession(
            configuration: configuration,
            delegate: UserConfiguredServiceRedirectDelegate(),
            delegateQueue: nil
        )
    }
}
