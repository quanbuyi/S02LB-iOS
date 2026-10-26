import Foundation
import Network

/// S02LB 眼镜原生异步 FTP 客户端 (基于 Network.framework / NWConnection)
///
/// 遵循 RFC 959 规范，针对 Busybox ftpd 优化：
/// - 支持被动模式 (PASV) 与二进制传输模式 (TYPE I)
/// - 自动枚举 /PIC_/ (照片) 与 /IMG_/ (录像) 目录
/// - 支持断点续传、文件大小获取与下载进度实时回调
public final class FtpClient {
    
    public enum FtpError: LocalizedError {
        case notConnected
        case connectionFailed(String)
        case commandFailed(String)
        case passiveModeFailed
        case fileTransferFailed(String)
        case invalidResponse
        
        public var errorDescription: String? {
            switch self {
            case .notConnected:
                return "FTP 尚未连接"
            case .connectionFailed(let reason):
                return "FTP 连接失败: \(reason)"
            case .commandFailed(let msg):
                return "FTP 指令执行失败: \(msg)"
            case .passiveModeFailed:
                return "进入被动模式 (PASV) 失败"
            case .fileTransferFailed(let msg):
                return "文件下载失败: \(msg)"
            case .invalidResponse:
                return "响应格式不合法"
            }
        }
    }
    
    public typealias ProgressHandler = (_ transferred: Int64, _ total: Int64, _ percent: Double) -> Void
    
    private var controlConnection: NWConnection?
    private var host: String = "192.168.43.1"
    private var isConnected: Bool = false
    private let queue = DispatchQueue(label: "com.s02lb.ftp.client", qos: .userInitiated)
    
    public init() {}
    
    deinit {
        disconnect()
    }
    
    // MARK: - 连接与鉴权
    
    /// 连接眼镜 FTP 服务 (默认尝试 anonymous，失败则尝试 ftp 用户名)
    public func connect(host: String = "192.168.43.1", port: UInt16 = 21, user: String = "anonymous", pass: String = "") async throws {
        disconnect()
        self.host = host
        
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw FtpError.connectionFailed("无效端口 \(port)")
        }
        
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: nwPort)
        let connection = NWConnection(to: endpoint, using: .tcp)
        self.controlConnection = connection
        
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let guardObj = ContinuationGuard()
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    guardObj.runOnce {
                        continuation.resume()
                    }
                case .failed(let err):
                    guardObj.runOnce {
                        continuation.resume(throwing: FtpError.connectionFailed(err.localizedDescription))
                    }
                default:
                    break
                }
            }
            connection.start(queue: self.queue)
        }
        
        // 读取 220 欢迎信息
        let banner = try await readReply()
        guard banner.hasPrefix("220") else {
            throw FtpError.commandFailed("服务器未就绪: \(banner)")
        }
        
        // 登录 USER
        let userReply = try await sendCommand("USER \(user)")
        if userReply.hasPrefix("331") {
            // 需要密码
            _ = try await sendCommand("PASS \(pass)")
        }
        
        // 设置二进制模式
        _ = try await sendCommand("TYPE I")
        self.isConnected = true
        S02Logger.shared.log("FTP 成功建立连接: \(host):\(port)", tag: "FTP")
    }
    
    /// 断开连接
    public func disconnect() {
        if isConnected {
            _ = try? sendCommandSync("QUIT\r\n")
        }
        controlConnection?.cancel()
        controlConnection = nil
        isConnected = false
    }
    
    // MARK: - 目录与媒体文件列表
    
    /// 枚举媒体文件 (自动探测 /PIC_/ 照片目录与 /IMG_/ 录像目录，并兼容相对路径)
    public func listMediaFiles() async throws -> [String] {
        guard isConnected else { throw FtpError.notConnected }
        
        var results: [String] = []
        
        // 1. 尝试获取 PIC_/ 照片列表 (兼容 /PIC_ 与 PIC_)
        if let pics = try? await listDirectory(path: "/PIC_"), !pics.isEmpty {
            for f in pics { results.append("PIC_/\(f)") }
        } else if let pics = try? await listDirectory(path: "PIC_"), !pics.isEmpty {
            for f in pics { results.append("PIC_/\(f)") }
        }
        
        // 2. 尝试获取 IMG_/ 录像列表 (兼容 /IMG_ 与 IMG_)
        if let imgs = try? await listDirectory(path: "/IMG_"), !imgs.isEmpty {
            for f in imgs { results.append("IMG_/\(f)") }
        } else if let imgs = try? await listDirectory(path: "IMG_"), !imgs.isEmpty {
            for f in imgs { results.append("IMG_/\(f)") }
        }
        
        // 3. 兜底扫描根目录
        if results.isEmpty {
            if let root = try? await listDirectory(path: "/") {
                for f in root {
                    if f.hasPrefix("PIC_") {
                        results.append("PIC_/\(f)")
                    } else if f.hasPrefix("IMG_") {
                        results.append("IMG_/\(f)")
                    } else {
                        results.append(f)
                    }
                }
            }
        }
        
        S02Logger.shared.log("FTP 文件扫描完成，找到 \(results.count) 个文件", tag: "FTP")
        return results
    }
    
    /// 列出指定目录下的文件列表
    public func listDirectory(path: String) async throws -> [String] {
        guard isConnected else { throw FtpError.notConnected }
        
        // 1. 进入被动模式获取数据通道端口
        let (dataHost, dataPort) = try await enterPassiveMode()
        
        // 2. 连接数据通道
        let dataConnection = try await openDataConnection(host: dataHost, port: dataPort)
        
        // 3. 优先发送 LIST 指令 (RFC 959 标准指令，对齐安卓 client.listFiles)，若失败则尝试 NLST
        var reply = try await sendCommand("LIST \(path)")
        if !reply.hasPrefix("150") && !reply.hasPrefix("125") {
            reply = try await sendCommand("NLST \(path)")
        }
        
        guard reply.hasPrefix("150") || reply.hasPrefix("125") else {
            dataConnection.cancel()
            if reply.hasPrefix("550") {
                // 目录不存在或为空 (例如未拍照)，正常返回空列表
                return []
            }
            throw FtpError.commandFailed("获取列表拒绝: \(reply)")
        }
        
        // 4. 从数据通道读取完整列表数据
        let rawData = try await readDataToEnd(connection: dataConnection)
        if !reply.contains("226") {
            _ = try? await readReply() // 消费 226 Transfer complete
        }
        
        guard let text = String(data: rawData, encoding: .utf8) ?? String(data: rawData, encoding: .ascii) else {
            return []
        }
        
        let lines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.hasPrefix(".") }
            .map { line -> String in
                // 若返回包含路径前缀，提取纯文件名
                if let idx = line.lastIndex(of: "/") {
                    return String(line[line.index(after: idx)...])
                }
                // 若为 ls -l 格式 (例如 "-rw-r--r-- 1 root root 12345 PIC_0001.JPG")
                if line.contains(" ") {
                    let parts = line.split(separator: " ").map(String.init)
                    if let last = parts.last, !last.isEmpty {
                        return last
                    }
                }
                return line
            }
            .filter { !$0.isEmpty }
        
        return lines
    }
    
    // MARK: - 文件下载
    
    /// 获取文件大小 (SIZE 指令)
    public func getFileSize(remotePath: String) async throws -> Int64 {
        guard isConnected else { throw FtpError.notConnected }
        let full = remotePath.hasPrefix("/") ? remotePath : "/\(remotePath)"
        let reply = try await sendCommand("SIZE \(full)")
        if reply.hasPrefix("213 ") {
            let numStr = reply.dropFirst(4).trimmingCharacters(in: .whitespacesAndNewlines)
            if let size = Int64(numStr) {
                return size
            }
        }
        return -1
    }
    
    /// 下载文件至指定的本地 URL (支持进度监听)
    @discardableResult
    public func download(remotePath: String, to localURL: URL, progress: ProgressHandler? = nil) async throws -> URL {
        guard isConnected else { throw FtpError.notConnected }
        
        let fullPath = remotePath.hasPrefix("/") ? remotePath : "/\(remotePath)"
        let totalSize = (try? await getFileSize(remotePath: fullPath)) ?? -1
        
        // 1. 进入被动模式
        let (dataHost, dataPort) = try await enterPassiveMode()
        
        // 2. 打开数据连接
        let dataConn = try await openDataConnection(host: dataHost, port: dataPort)
        
        // 3. 发送 RETR 指令
        let reply = try await sendCommand("RETR \(fullPath)")
        guard reply.hasPrefix("150") || reply.hasPrefix("125") else {
            dataConn.cancel()
            throw FtpError.commandFailed("RETR 拒绝: \(reply)")
        }
        
        // 4. 流式写入本地文件
        if FileManager.default.fileExists(atPath: localURL.path) {
            try? FileManager.default.removeItem(at: localURL)
        }
        
        FileManager.default.createFile(atPath: localURL.path, contents: nil)
        guard let fileHandle = try? FileHandle(forWritingTo: localURL) else {
            dataConn.cancel()
            throw FtpError.fileTransferFailed("无法创建本地文件写入句柄: \(localURL.path)")
        }
        defer {
            try? fileHandle.close()
        }
        
        var transferred: Int64 = 0
        try await streamData(connection: dataConn) { chunk in
            fileHandle.write(chunk)
            transferred += Int64(chunk.count)
            let pct = totalSize > 0 ? min(1.0, Double(transferred) / Double(totalSize)) : 0.0
            progress?(transferred, totalSize, pct)
        }
        
        // 5. 消费 226 Transfer complete 响应
        let completeReply = try await readReply()
        guard completeReply.hasPrefix("226") else {
            throw FtpError.fileTransferFailed("传输未完全成功: \(completeReply)")
        }
        
        progress?(transferred, totalSize, 1.0)
        S02Logger.shared.log("文件下载成功: \(remotePath) -> \(localURL.lastPathComponent) (\(transferred) 字节)", tag: "FTP")
        return localURL
    }
    
    // MARK: - 辅助协议指令封装
    
    private func sendCommand(_ cmd: String) async throws -> String {
        guard let conn = controlConnection else { throw FtpError.notConnected }
        let payload = "\(cmd)\r\n".data(using: .ascii)!
        
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            conn.send(content: payload, completion: .contentProcessed { error in
                if let err = error {
                    continuation.resume(throwing: err)
                } else {
                    continuation.resume()
                }
            })
        }
        
        return try await readReply()
    }
    
    private func sendCommandSync(_ cmd: String) throws {
        guard let conn = controlConnection else { return }
        let data = cmd.data(using: .ascii)!
        conn.send(content: data, completion: .contentProcessed { _ in })
    }
    
    private func readReply() async throws -> String {
        guard let conn = controlConnection else { throw FtpError.notConnected }
        
        return try await withCheckedThrowingContinuation { continuation in
            conn.receive(minimumIncompleteLength: 1, maximumLength: 1024) { data, _, _, error in
                if let err = error {
                    continuation.resume(throwing: err)
                } else if let d = data, let text = String(data: d, encoding: .ascii) {
                    continuation.resume(returning: text.trimmingCharacters(in: .whitespacesAndNewlines))
                } else {
                    continuation.resume(throwing: FtpError.invalidResponse)
                }
            }
        }
    }
    
    /// 解析 227 Entering Passive Mode (h1,h2,h3,h4,p1,p2)
    private func enterPassiveMode() async throws -> (String, UInt16) {
        let reply = try await sendCommand("PASV")
        guard reply.hasPrefix("227") else {
            throw FtpError.passiveModeFailed
        }
        
        guard let start = reply.firstIndex(of: "("),
              let end = reply.firstIndex(of: ")") else {
            throw FtpError.passiveModeFailed
        }
        
        let sub = reply[reply.index(after: start)..<end]
        let parts = sub.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        guard parts.count == 6 else {
            throw FtpError.passiveModeFailed
        }
        
        let p1 = parts[4]
        let p2 = parts[5]
        let port = UInt16((p1 << 8) | p2)
        
        // 优先使用当前连接的主机 IP（避免部分设备返回 127.0.0.1 或内网不同网段）
        let targetHost = self.host
        return (targetHost, port)
    }
    
    private func openDataConnection(host: String, port: UInt16) async throws -> NWConnection {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw FtpError.connectionFailed("无效数据端口 \(port)")
        }
        
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: nwPort)
        let dataConn = NWConnection(to: endpoint, using: .tcp)
        
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let guardObj = ContinuationGuard()
            dataConn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    guardObj.runOnce {
                        continuation.resume()
                    }
                case .failed(let err):
                    guardObj.runOnce {
                        continuation.resume(throwing: FtpError.connectionFailed(err.localizedDescription))
                    }
                default:
                    break
                }
            }
            dataConn.start(queue: self.queue)
        }
        return dataConn
    }
    
    private func readDataToEnd(connection: NWConnection) async throws -> Data {
        var buffer = Data()
        while true {
            let chunk: Data = try await withCheckedThrowingContinuation { continuation in
                let guardObj = ContinuationGuard()
                connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
                    // 1. 若收到有效数据片段，正常交付
                    if let d = data, !d.isEmpty {
                        guardObj.runOnce { continuation.resume(returning: d) }
                        return
                    }
                    // 2. 若对端正常关闭连接 (EOF)，返回空数据退出
                    if isComplete {
                        guardObj.runOnce { continuation.resume(returning: Data()) }
                        return
                    }
                    // 3. 处理异常并识别 POSIX 正常 EOF (code 0)
                    if let err = error {
                        if case .posix(let posixErr) = err, posixErr.rawValue == 0 {
                            guardObj.runOnce { continuation.resume(returning: Data()) }
                            return
                        }
                        guardObj.runOnce { continuation.resume(throwing: err) }
                        return
                    }
                    // 4. 其他情况默认返回空数据
                    guardObj.runOnce { continuation.resume(returning: Data()) }
                }
            }
            if chunk.isEmpty {
                break
            }
            buffer.append(chunk)
        }
        connection.cancel()
        return buffer
    }
    
    private func streamData(connection: NWConnection, onChunk: @escaping (Data) -> Void) async throws {
        while true {
            let chunk: Data = try await withCheckedThrowingContinuation { continuation in
                let guardObj = ContinuationGuard()
                connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
                    // 1. 若收到有效数据片段，正常交付
                    if let d = data, !d.isEmpty {
                        guardObj.runOnce { continuation.resume(returning: d) }
                        return
                    }
                    // 2. 若对端正常关闭连接 (EOF)，返回空数据退出
                    if isComplete {
                        guardObj.runOnce { continuation.resume(returning: Data()) }
                        return
                    }
                    // 3. 处理异常并识别 POSIX 正常 EOF (code 0)
                    if let err = error {
                        if case .posix(let posixErr) = err, posixErr.rawValue == 0 {
                            guardObj.runOnce { continuation.resume(returning: Data()) }
                            return
                        }
                        guardObj.runOnce { continuation.resume(throwing: err) }
                        return
                    }
                    // 4. 其他情况默认返回空数据
                    guardObj.runOnce { continuation.resume(returning: Data()) }
                }
            }
            if chunk.isEmpty {
                break
            }
            onChunk(chunk)
        }
        connection.cancel()
    }
}
