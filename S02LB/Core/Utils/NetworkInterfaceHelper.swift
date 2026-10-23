import Foundation
import Darwin

/// iOS 本地网络接口与 IP 探测工具
public struct NetworkInterfaceHelper {
    
    /// 获取当前 iOS 设备 Wi-Fi 网卡 (en0) 分配的 IPv4 地址
    /// - Returns: IPv4 字符串 (如 "192.168.43.15" 或 "192.168.1.108")，未接入 Wi-Fi 时返回 nil
    public static func getWifiIPv4Address() -> String? {
        var address: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }
        
        var ptr = firstAddr
        while true {
            let interface = ptr.pointee
            let addrFamily = interface.ifa_addr.pointee.sa_family
            if addrFamily == UInt8(AF_INET) {
                let name = String(cString: interface.ifa_name)
                // iOS 设备的 Wi-Fi 物理网卡名称固定为 "en0"
                if name == "en0" {
                    var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    let saLen = socklen_t(MemoryLayout<sockaddr_in>.size)
                    if getnameinfo(interface.ifa_addr, saLen,
                                   &hostname, socklen_t(hostname.count),
                                   nil, 0, NI_NUMERICHOST) == 0 {
                        address = String(cString: hostname)
                        break
                    }
                }
            }
            guard let next = interface.ifa_next else { break }
            ptr = next
        }
        return address
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
