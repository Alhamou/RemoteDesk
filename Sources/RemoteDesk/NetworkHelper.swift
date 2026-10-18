import Darwin
import Foundation

enum NetworkHelper {
    static func localIPv4() -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }

        var primaryAddress: String?
        var ptr: UnsafeMutablePointer<ifaddrs>? = firstAddr
        while let p = ptr {
            let flags = Int32(p.pointee.ifa_flags)
            let saFamily = p.pointee.ifa_addr.pointee.sa_family
            if (flags & (IFF_UP | IFF_RUNNING | IFF_LOOPBACK)) == (IFF_UP | IFF_RUNNING) {
                if saFamily == UInt8(AF_INET) {
                    var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    if getnameinfo(p.pointee.ifa_addr, socklen_t(p.pointee.ifa_addr.pointee.sa_len), &hostname, socklen_t(hostname.count), nil, 0, NI_NUMERICHOST) == 0 {
                        let name = String(cString: p.pointee.ifa_name)
                        let ip = String(cString: hostname)
                        if name == "en0" {
                            return ip
                        }
                        if primaryAddress == nil {
                            primaryAddress = ip
                        }
                    }
                }
            }
            ptr = p.pointee.ifa_next
        }
        return primaryAddress
    }
}
