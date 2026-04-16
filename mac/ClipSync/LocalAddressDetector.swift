import Foundation

enum LocalAddressDetector {
    static func allIPv4Addresses() -> [String] {
        var addresses: [String] = []
        var interfaces: UnsafeMutablePointer<ifaddrs>?

        guard getifaddrs(&interfaces) == 0, let first = interfaces else {
            return []
        }

        defer { freeifaddrs(interfaces) }

        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let interface = pointer.pointee
            guard let addr = interface.ifa_addr else { continue }
            let family = addr.pointee.sa_family
            guard family == UInt8(AF_INET) else { continue }

            let name = String(cString: interface.ifa_name)
            guard name != "lo0" else { continue }

            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(
                addr,
                socklen_t(addr.pointee.sa_len),
                &hostname,
                socklen_t(hostname.count),
                nil,
                0,
                NI_NUMERICHOST
            )

            let candidate = String(cString: hostname)
            guard !candidate.isEmpty,
                  !candidate.hasPrefix("169.254."),
                  !addresses.contains(candidate) else {
                continue
            }

            addresses.append(candidate)
        }

        return addresses
    }

    static func primaryIPv4Address() -> String {
        allIPv4Addresses().first ?? "127.0.0.1"
    }

    static func baseURLs(port: Int) -> [String] {
        allIPv4Addresses().map { "http://\($0):\(port)" }
    }
}
