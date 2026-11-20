import Foundation

/// Kontrola adresy přijímače (stejná pravidla jako Android `PushEndpointPolicy`):
/// HTTPS kamkoli, prostý HTTP jen na číselné privátní adresy. Názvy hostů (i `.local`, `localhost`)
/// se u HTTP odmítají, aby DNS nemohl přesunout povolenou adresu na veřejnou.
public enum EndpointPolicy {
    public struct Invalid: Error, Equatable { public let reason: String }

    public static func validate(_ text: String) throws -> URL {
        guard var c = URLComponents(string: text.trimmingCharacters(in: .whitespaces)) else { throw Invalid(reason: "format") }
        guard let scheme = c.scheme?.lowercased(), scheme == "http" || scheme == "https" else { throw Invalid(reason: "scheme") }
        guard c.user == nil, c.password == nil else { throw Invalid(reason: "userinfo") }
        guard c.fragment == nil else { throw Invalid(reason: "fragment") }
        guard let rawHost = c.host, !rawHost.isEmpty else { throw Invalid(reason: "host") }
        let host = rawHost.lowercased()
        if scheme == "http", !isPrivateNumeric(host) { throw Invalid(reason: "cleartext") }
        c.scheme = scheme
        c.host = host
        if (scheme == "https" && c.port == 443) || (scheme == "http" && c.port == 80) { c.port = nil }
        if c.path.isEmpty { c.path = "/" }
        guard let url = c.url else { throw Invalid(reason: "format") }
        return url
    }

    static func isPrivateNumeric(_ host: String) -> Bool {
        let bare = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        var v4 = in_addr()
        if inet_pton(AF_INET, bare, &v4) == 1 {
            let b = withUnsafeBytes(of: &v4) { Array($0) }
            return b[0] == 10 || b[0] == 127 || (b[0] == 172 && (16...31).contains(b[1])) || (b[0] == 192 && b[1] == 168) || (b[0] == 169 && b[1] == 254)
        }
        var v6 = in6_addr()
        if inet_pton(AF_INET6, bare, &v6) == 1 {
            let b = withUnsafeBytes(of: &v6) { Array($0) }
            let loopback = b.dropLast().allSatisfy { $0 == 0 } && b[15] == 1
            let linkLocal = b[0] == 0xfe && (b[1] & 0xc0) == 0x80
            let ula = (b[0] & 0xfe) == 0xfc
            return loopback || linkLocal || ula
        }
        return false
    }
}
