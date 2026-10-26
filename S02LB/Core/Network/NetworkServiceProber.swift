import Foundation
import Network

/// 局域网目标设备服务可达性探测器 (针对 21 端口 FTP 与 554 端口 RTSP DESCRIBE)
public final class NetworkServiceProber {
    
    public struct ProbeResult {
        public let isReachable: Bool
        public let detail: String
        public let sdp: String?
    }
    
    public static let shared = NetworkServiceProber()
    private init() {}
    
    // MARK: - 探测 FTP 服务 (21 端口)
    
    /// 探测 FTP 是否响应 220 欢迎标头
    public func probeFtp(host: String, port: UInt16 = 21, timeoutSeconds: Double = 1.5) async -> Bool {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return false }
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: nwPort)
        let params = NWParameters.tcp
        
        let connection = NWConnection(to: endpoint, using: params)
        
        return await withCheckedContinuation { continuation in
            let queue = DispatchQueue(label: "com.s02lb.probe.ftp")
            let guardObj = ContinuationGuard()
            
            let finish: (Bool) -> Void = { result in
                guardObj.runOnce {
                    connection.cancel()
                    continuation.resume(returning: result)
                }
            }
            
            // 超时保护
            queue.asyncAfter(deadline: .now() + timeoutSeconds) {
                finish(false)
            }
            
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    // 连接成功，读取 FTP 欢迎横幅 (以 220 开头)
                    connection.receive(minimumIncompleteLength: 1, maximumLength: 128) { data, _, _, error in
                        if let data = data, let banner = String(data: data, encoding: .ascii) {
                            let ok = banner.hasPrefix("220 ") || banner.hasPrefix("220-")
                            finish(ok)
                        } else {
                            finish(false)
                        }
                    }
                case .failed, .cancelled:
                    finish(false)
                default:
                    break
                }
            }
            
            connection.start(queue: queue)
        }
    }
    
    // MARK: - 探测 RTSP 服务 (DESCRIBE 方法校验 SDP)
    
    /// 向指定 RTSP 地址下发 DESCRIBE 请求并校验是否返回有效的 SDP 视频轨
    public func probeRtsp(url: URL, timeoutSeconds: Double = 2.0) async -> ProbeResult {
        let host = url.host ?? "192.168.43.1"
        let port = UInt16(url.port ?? 554)
        
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            return ProbeResult(isReachable: false, detail: "无效端口", sdp: nil)
        }
        
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: nwPort)
        let params = NWParameters.tcp
        let connection = NWConnection(to: endpoint, using: params)
        
        return await withCheckedContinuation { continuation in
            let queue = DispatchQueue(label: "com.s02lb.probe.rtsp")
            let guardObj = ContinuationGuard()
            
            let finish: (ProbeResult) -> Void = { result in
                guardObj.runOnce {
                    connection.cancel()
                    continuation.resume(returning: result)
                }
            }
            
            queue.asyncAfter(deadline: .now() + timeoutSeconds) {
                finish(ProbeResult(isReachable: false, detail: "RTSP 探测超时", sdp: nil))
            }
            
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    let request = "DESCRIBE \(url.absoluteString) RTSP/1.0\r\nCSeq: 1\r\nAccept: application/sdp\r\nUser-Agent: S02LB-iOS-probe\r\n\r\n"
                    guard let reqData = request.data(using: .ascii) else {
                        finish(ProbeResult(isReachable: false, detail: "编码失败", sdp: nil))
                        return
                    }
                    
                    connection.send(content: reqData, completion: .contentProcessed { sendError in
                        if let error = sendError {
                            finish(ProbeResult(isReachable: false, detail: "发送请求失败: \(error.localizedDescription)", sdp: nil))
                            return
                        }
                        
                        // 读取响应
                        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, _, recvError in
                            if let data = data, let respStr = String(data: data, encoding: .ascii) {
                                // 校验 RTSP/1.0 200 OK 响应
                                if respStr.contains("RTSP/1.0 200") {
                                    finish(ProbeResult(isReachable: true, detail: "RTSP 服务已响应 200 OK", sdp: respStr))
                                    return
                                }
                                finish(ProbeResult(isReachable: false, detail: "未就绪: \(respStr.prefix(60))", sdp: nil))
                            } else {
                                finish(ProbeResult(isReachable: false, detail: "未收到有效数据", sdp: nil))
                            }
                        }
                    })
                case .failed(let err):
                    finish(ProbeResult(isReachable: false, detail: "连接失败: \(err.localizedDescription)", sdp: nil))
                case .cancelled:
                    finish(ProbeResult(isReachable: false, detail: "连接取消", sdp: nil))
                default:
                    break
                }
            }
            
            connection.start(queue: queue)
        }
    }
}
