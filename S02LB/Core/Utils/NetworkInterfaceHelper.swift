import Foundation
import Darwin

/// iOS 本地网络接口与 IP 探测工具
public struct NetworkInterfaceHelper {
    
    /// 获取当前 iOS 设备 Wi-Fi 物理网卡 (en0/en1 等) 分配的 IPv4 地址
    /// - Returns: IPv4 字符串 (如 "192.168.43.15" 或 "192.168.1.108")，未接入 Wi-Fi 时返回 nil
    public static func getWifiIPv4Address() -> String? {
        var fallbackAddress: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }
        
        var ptr = firstAddr
        while true {
            let interface = ptr.pointee
            let addrFamily = interface.ifa_addr.pointee.sa_family
            if addrFamily == UInt8(AF_INET) {
                let name = String(cString: interface.ifa_name)
                // 兼容 en0, en1, en2 等所有物理局域网网卡 (排除回环 lo0 与蜂窝 pdp_ip)
                if name.hasPrefix("en") {
                    var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    let saLen = socklen_t(MemoryLayout<sockaddr_in>.size)
                    if getnameinfo(interface.ifa_addr, saLen,
                                   &hostname, socklen_t(hostname.count),
                                   nil, 0, NI_NUMERICHOST) == 0 {
                        let ip = String(cString: hostname)
                        if !ip.isEmpty && ip != "0.0.0.0" && !ip.hasPrefix("127.") {
                            // 若直接匹配眼镜默认热点网段 192.168.43.x，立即优先返回！
                            if isSameSubnet(ipA: ip, ipB: "192.168.43.1") {
                                return ip
                            }
                            if fallbackAddress == nil {
                                fallbackAddress = ip
                            }
                        }
                    }
                }
            }
            guard let next = interface.ifa_next else { break }
            ptr = next
        }
        return fallbackAddress
    }
    
    /// 获取当前设备所有活动网络接口的简要信息 (供诊断日志精准输出)
    public static func getAllNetworkInterfacesSummary() -> String {
        var summaries: [String] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else { return "无网络接口信息" }
        defer { freeifaddrs(ifaddr) }
        
        var ptr = firstAddr
        while true {
            let interface = ptr.pointee
            let addrFamily = interface.ifa_addr.pointee.sa_family
            if addrFamily == UInt8(AF_INET) {
                let name = String(cString: interface.ifa_name)
                var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                let saLen = socklen_t(MemoryLayout<sockaddr_in>.size)
                if getnameinfo(interface.ifa_addr, saLen,
                               &hostname, socklen_t(hostname.count),
                               nil, 0, NI_NUMERICHOST) == 0 {
                    let ip = String(cString: hostname)
                    if !ip.hasPrefix("127.") {
                        summaries.append("\(name):\(ip)")
                    }
                }
            }
            guard let next = interface.ifa_next else { break }
            ptr = next
        }
        return summaries.isEmpty ? "物理网卡未分配 IPv4" : summaries.joined(separator: ", ")
    }
    
    /// 校验两个 IPv4 是否处于同一 C 类局域网子网 (前三段匹配，如 192.168.43.x)
    public static func isSameSubnet(ipA: String?, ipB: String?) -> Bool {
        guard let a = ipA, let b = ipB else { return false }
        let partsA = a.split(separator: ".")
        let partsB = b.split(separator: ".")
        guard partsA.count == 4, partsB.count == 4 else { return false }
        return partsA[0] == partsB[0] && partsA[1] == partsB[1] && partsA[2] == partsB[2]
    }
}
