import Foundation
import UIKit
import AVFoundation
import VideoToolbox
import Network
import Combine

/// 基于 AVSampleBufferDisplayLayer 的 4:3 比例硬件加速渲染视图
public final class SampleBufferVideoView: UIView {
    
    public override class var layerClass: AnyClass {
        return AVSampleBufferDisplayLayer.self
    }
    
    public var sampleBufferLayer: AVSampleBufferDisplayLayer {
        return layer as! AVSampleBufferDisplayLayer
    }
    
    public override init(frame: CGRect) {
        super.init(frame: frame)
        setupLayer()
    }
    
    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupLayer()
    }
    
    private func setupLayer() {
        backgroundColor = .black
        sampleBufferLayer.videoGravity = .resizeAspect
        sampleBufferLayer.preventsDisplaySleepDuringVideoPlayback = true
    }
}

/// 纯 Swift 实现的高性能低延迟原生 RTSP H.264 播放器
/// 无需任何三方二进制依赖 (MobileVLCKit/FFmpeg)，直接利用 iOS 原生 VideoToolbox 硬解及 AVSampleBufferDisplayLayer 渲染
public class NativeRtspPlayer: NSObject, RtspPlayerProtocol {
    
    public var statePublisher: AnyPublisher<RtspPlaybackState, Never> {
        stateSubject.eraseToAnyPublisher()
    }
    
    public private(set) var currentState: RtspPlaybackState = .idle {
        didSet {
            stateSubject.send(currentState)
        }
    }
    
    public let renderView: UIView
    public private(set) var firstFrameLatencyMs: Int? = nil
    
    private let videoView: SampleBufferVideoView
    private let stateSubject = CurrentValueSubject<RtspPlaybackState, Never>(.idle)
    
    // 网络与连接
    private var connection: NWConnection?
    private var udpListener: NWListener?
    private let workerQueue = DispatchQueue(label: "com.s02lb.native.rtsp.queue", qos: .userInitiated)
    private var receiveBuffer = Data()
    
    // RTSP 协议状态
    private var currentUrl: String = ""
    private var host: String = "192.168.43.1"
    private var port: UInt16 = 554
    private var path: String = "/6600"
    private var cseq: Int = 0
    private var sessionId: String? = nil
    private var trackControlUrl: String = ""
    private var hasSentPlay: Bool = false
    private var playStartTime: Date?
    private var keepAliveTimer: DispatchSourceTimer?
    
    // H.264 解码与 RTP 重组
    private var formatDescription: CMVideoFormatDescription?
    private var spsData: Data?
    private var ppsData: Data?
    private var currentNalUnits: [Data] = []
    private var currentFuBuffer = Data()
    
    public override init() {
        let view = SampleBufferVideoView(frame: .zero)
        self.videoView = view
        self.renderView = view
        super.init()
    }
    
    // MARK: - RtspPlayerProtocol
    
    public func play(url: String) {
        stop()
        
        var targetUrl = url.trimmingCharacters(in: .whitespacesAndNewlines)
        if targetUrl.isEmpty {
            targetUrl = "rtsp://192.168.43.1:554/6600"
        }
        if !targetUrl.contains("://") {
            targetUrl = "rtsp://" + targetUrl
        }
        
        self.currentUrl = targetUrl
        self.playStartTime = Date()
        self.firstFrameLatencyMs = nil
        self.cseq = 0
        self.sessionId = nil
        self.trackControlUrl = ""
        self.hasSentPlay = false
        self.currentState = .connecting(targetUrl)
        
        S02Logger.shared.log("启动原生 RTSP 低延迟拉流播放器: \(targetUrl)", tag: "NativeRTSP")
        
        // 解析主机、端口与路径
        if let parsed = URL(string: targetUrl) {
            self.host = parsed.host ?? "192.168.43.1"
            self.port = UInt16(parsed.port ?? 554)
            self.path = parsed.path.isEmpty ? "/6600" : parsed.path
        }
        
        connectAndStartRtsp()
    }
    
    public func stop() {
        stopInternal(silent: false)
    }
    
    public func pause() {
        self.currentState = .buffering
    }
    
    public func resume() {
        if case .buffering = currentState {
            self.currentState = .playing(url: currentUrl, latencyMs: firstFrameLatencyMs)
        }
    }
    
    // MARK: - 内部网络与 RTSP 交互
    
    private func stopInternal(silent: Bool) {
        // 先同步更新状态，确保外部读取与测试同步即时
        self.currentState = .idle
        
        workerQueue.async { [weak self] in
            guard let self = self else { return }
            
            self.keepAliveTimer?.cancel()
            self.keepAliveTimer = nil
            
            self.udpListener?.cancel()
            self.udpListener = nil
            
            if let sess = self.sessionId, let conn = self.connection {
                self.cseq += 1
                let teardown = "TEARDOWN \(self.currentUrl) RTSP/1.0\r\nCSeq: \(self.cseq)\r\nSession: \(sess)\r\nUser-Agent: S02LB iOS\r\n\r\n"
                if let data = teardown.data(using: .utf8) {
                    conn.send(content: data, completion: .contentProcessed({ _ in }))
                }
            }
            
            self.connection?.cancel()
            self.connection = nil
            self.sessionId = nil
            self.receiveBuffer.removeAll()
            self.currentNalUnits.removeAll()
            self.currentFuBuffer.removeAll()
            self.formatDescription = nil
            self.spsData = nil
            self.ppsData = nil
            
            DispatchQueue.main.async {
                self.videoView.sampleBufferLayer.flushAndRemoveImage()
                if !silent {
                    S02Logger.shared.log("已停止 RTSP 拉流并释放解码缓存", tag: "NativeRTSP")
                }
            }
        }
    }
    
    private func connectAndStartRtsp() {
        workerQueue.async { [weak self] in
            guard let self = self else { return }
            
            let nwHost = NWEndpoint.Host(self.host)
            let nwPort = NWEndpoint.Port(rawValue: self.port) ?? .init(integerLiteral: 554)
            let params = NWParameters.tcp
            params.prohibitExpensivePaths = false
            params.prohibitConstrainedPaths = false
            
            let conn = NWConnection(host: nwHost, port: nwPort, using: params)
            self.connection = conn
            
            conn.stateUpdateHandler = { [weak self] newState in
                guard let self = self else { return }
                switch newState {
                case .ready:
                    S02Logger.shared.log("RTSP TCP 链路就绪 (\(self.host):\(self.port))，开始协议协商...", tag: "NativeRTSP")
                    self.sendOptions()
                    self.startReceiveLoop()
                case .failed(let error):
                    S02Logger.shared.log("RTSP TCP 连接失败: \(error)", tag: "NativeRTSP")
                    DispatchQueue.main.async {
                        self.currentState = .error("连接失败: \(error.localizedDescription)")
                    }
                case .waiting(let error):
                    S02Logger.shared.log("RTSP 连接等待中: \(error)", tag: "NativeRTSP")
                default:
                    break
                }
            }
            
            conn.start(queue: self.workerQueue)
        }
    }
    
    private func sendOptions() {
        cseq += 1
        let req = "OPTIONS \(currentUrl) RTSP/1.0\r\nCSeq: \(cseq)\r\nUser-Agent: S02LB iOS\r\n\r\n"
        sendRaw(req)
    }
    
    private func sendDescribe() {
        cseq += 1
        let req = "DESCRIBE \(currentUrl) RTSP/1.0\r\nCSeq: \(cseq)\r\nAccept: application/sdp\r\nUser-Agent: S02LB iOS\r\n\r\n"
        sendRaw(req)
    }
    
    private func sendSetup() {
        cseq += 1
        let targetTrack = trackControlUrl.isEmpty ? "\(currentUrl)/track0" : trackControlUrl
        let req = "SETUP \(targetTrack) RTSP/1.0\r\nCSeq: \(cseq)\r\nTransport: RTP/AVP/TCP;unicast;interleaved=0-1\r\nUser-Agent: S02LB iOS\r\n\r\n"
        sendRaw(req)
    }
    
    private func sendPlay() {
        guard !hasSentPlay else { return }
        hasSentPlay = true
        cseq += 1
        let sessionHeader = (sessionId != nil) ? "Session: \(sessionId!)\r\n" : ""
        let req = "PLAY \(currentUrl) RTSP/1.0\r\nCSeq: \(cseq)\r\n\(sessionHeader)Range: npt=0.000-\r\nUser-Agent: S02LB iOS\r\n\r\n"
        sendRaw(req)
        
        startKeepAliveTimer()
    }
    
    private func sendRaw(_ string: String) {
        guard let data = string.data(using: .utf8), let conn = connection else { return }
        conn.send(content: data, completion: .contentProcessed({ error in
            if let err = error {
                S02Logger.shared.log("RTSP 发送失败: \(err)", tag: "NativeRTSP")
            }
        }))
    }
    
    private func startKeepAliveTimer() {
        keepAliveTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: workerQueue)
        timer.schedule(deadline: .now() + 15.0, repeating: 15.0)
        timer.setEventHandler { [weak self] in
            guard let self = self, let sess = self.sessionId else { return }
            self.cseq += 1
            let ping = "OPTIONS \(self.currentUrl) RTSP/1.0\r\nCSeq: \(self.cseq)\r\nSession: \(sess)\r\nUser-Agent: S02LB iOS\r\n\r\n"
            self.sendRaw(ping)
        }
        timer.resume()
        self.keepAliveTimer = timer
    }
    
    // MARK: - 数据接收与分包解析
    
    private func startReceiveLoop() {
        guard let conn = connection else { return }
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] content, _, isComplete, error in
            guard let self = self else { return }
            
            if let data = content, !data.isEmpty {
                self.receiveBuffer.append(data)
                self.processReceiveBuffer()
            }
            
            if let err = error {
                S02Logger.shared.log("RTSP 链路接收异常: \(err)", tag: "NativeRTSP")
                DispatchQueue.main.async {
                    if case .playing = self.currentState {
                        self.currentState = .error("推流中断: \(err.localizedDescription)")
                    }
                }
                return
            }
            
            if isComplete {
                S02Logger.shared.log("RTSP 服务端主动关闭了流", tag: "NativeRTSP")
                return
            }
            
            self.startReceiveLoop()
        }
    }
    
    private func processReceiveBuffer() {
        while receiveBuffer.count >= 4 {
            let firstByte = receiveBuffer[0]
            
            if firstByte == 0x24 { // '$' 表示 TCP Interleaved 二进制 RTP 数据包
                let channel = receiveBuffer[1]
                let length = (Int(receiveBuffer[2]) << 8) | Int(receiveBuffer[3])
                let totalLen = 4 + length
                
                if receiveBuffer.count < totalLen {
                    // 数据包未收全，等待下一次 TCP 片段
                    break
                }
                
                let packetData = receiveBuffer.subdata(in: 4 ..< totalLen)
                receiveBuffer.removeSubrange(0 ..< totalLen)
                
                if channel == 0 {
                    handleRtpPacket(packetData)
                }
            } else {
                // RTSP 文本控制协议响应
                if let delimiterRange = receiveBuffer.range(of: Data([0x0D, 0x0A, 0x0D, 0x0A])) {
                    let headerData = receiveBuffer.subdata(in: 0 ..< delimiterRange.lowerBound)
                    let headerText = String(data: headerData, encoding: .utf8) ?? ""
                    
                    var contentLength = 0
                    if let clRange = headerText.range(of: "Content-Length:", options: .caseInsensitive) {
                        let sub = headerText[clRange.upperBound...]
                        if let end = sub.firstIndex(of: "\r") {
                            let str = sub[..<end].trimmingCharacters(in: .whitespaces)
                            contentLength = Int(str) ?? 0
                        }
                    }
                    
                    let totalResponseLen = delimiterRange.upperBound + contentLength
                    if receiveBuffer.count < totalResponseLen {
                        // SDP 正文尚未完全接收
                        break
                    }
                    
                    let responseData = receiveBuffer.subdata(in: 0 ..< totalResponseLen)
                    receiveBuffer.removeSubrange(0 ..< totalResponseLen)
                    handleRtspResponse(responseData)
                } else {
                    // 若无换行分隔符，查找下一个 '$' 重新对齐
                    if let nextDollar = receiveBuffer.firstIndex(of: 0x24) {
                        receiveBuffer.removeSubrange(0 ..< nextDollar)
                    } else if receiveBuffer.count > 4096 {
                        receiveBuffer.removeAll()
                    }
                    break
                }
            }
        }
    }
    
    private func handleRtspResponse(_ data: Data) {
        guard let text = String(data: data, encoding: .utf8) else { return }
        S02Logger.shared.log("收到 RTSP 响应:\n\(text.prefix(200))", tag: "NativeRTSP")
        
        // 提取 Session ID
        if let sRange = text.range(of: "Session:", options: .caseInsensitive) {
            let sub = text[sRange.upperBound...]
            let raw = sub.prefix(while: { $0 != "\r" && $0 != "\n" && $0 != ";" })
            self.sessionId = raw.trimmingCharacters(in: .whitespaces)
        }
        
        // 检查 461 传输不支持 (若服务端不支持 TCP interleaved，降级为 UDP 50000 端口)
        if text.contains("461") {
            S02Logger.shared.log("服务端不支持 TCP Interleaved，切换至 UDP (端口 50000)...", tag: "NativeRTSP")
            startUdpListener(port: 50000)
            cseq += 1
            let targetTrack = trackControlUrl.isEmpty ? "\(currentUrl)/track0" : trackControlUrl
            let req = "SETUP \(targetTrack) RTSP/1.0\r\nCSeq: \(cseq)\r\nTransport: RTP/AVP;unicast;client_port=50000-50001\r\nUser-Agent: S02LB iOS\r\n\r\n"
            sendRaw(req)
            return
        }
        
        if text.contains("Public:") || text.contains("OPTIONS") {
            sendDescribe()
        } else if text.contains("application/sdp") || text.contains("m=video") {
            parseSdpAndSetup(sdp: text)
        } else if text.contains("Transport:") || (sessionId != nil && !hasSentPlay) {
            if text.contains("client_port=") || text.contains("server_port=") {
                startUdpListener(port: 50000)
            }
            sendPlay()
        }
    }
    
    private func startUdpListener(port: UInt16 = 50000) {
        guard udpListener == nil else { return }
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return }
        do {
            let params = NWParameters.udp
            params.allowLocalEndpointReuse = true
            let listener = try NWListener(using: params, on: nwPort)
            listener.newConnectionHandler = { [weak self] newConn in
                guard let self = self else { return }
                newConn.start(queue: self.workerQueue)
                self.receiveUdpPackets(on: newConn)
            }
            listener.start(queue: self.workerQueue)
            self.udpListener = listener
            S02Logger.shared.log("RTSP UDP 接收监听器已在端口 \(port) 启动", tag: "NativeRTSP")
        } catch {
            S02Logger.shared.log("启动 UDP 监听异常: \(error)", tag: "NativeRTSP")
        }
    }
    
    private func receiveUdpPackets(on conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] content, _, isComplete, error in
            guard let self = self else { return }
            if let packet = content, !packet.isEmpty {
                self.handleRtpPacket(packet)
            }
            if error == nil && !isComplete {
                self.receiveUdpPackets(on: conn)
            }
        }
    }
    
    private func parseSdpAndSetup(sdp: String) {
        // 1. 尝试从 fmtp 中提取 sprop-parameter-sets (Base64 SPS/PPS)
        if let range = sdp.range(of: "sprop-parameter-sets=") {
            let sub = sdp[range.upperBound...]
            let paramString = sub.prefix(while: { $0 != "\r" && $0 != "\n" && $0 != ";" })
            let parts = paramString.split(separator: ",")
            if parts.count >= 2 {
                if let sps = Data(base64Encoded: String(parts[0])),
                   let pps = Data(base64Encoded: String(parts[1])) {
                    self.spsData = sps
                    self.ppsData = pps
                    updateFormatDescription(sps: sps, pps: pps)
                }
            }
        }
        
        // 2. 确定 track 控制地址
        var trackName = ""
        let lines = sdp.components(separatedBy: "\n")
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("a=control:") {
                let val = String(trimmed.dropFirst("a=control:".count)).trimmingCharacters(in: .whitespaces)
                if !val.isEmpty && val != "*" {
                    trackName = val
                }
            }
        }
        
        if trackName.hasPrefix("rtsp://") {
            self.trackControlUrl = trackName
        } else if !trackName.isEmpty {
            self.trackControlUrl = currentUrl.hasSuffix("/") ? "\(currentUrl)\(trackName)" : "\(currentUrl)/\(trackName)"
        } else {
            self.trackControlUrl = "\(currentUrl)/track0"
        }
        
        sendSetup()
    }
    
    // MARK: - RTP 解析与 H.264 解码渲染
    
    private func handleRtpPacket(_ packet: Data) {
        guard packet.count >= 12 else { return }
        let v_p_x_cc = packet[0]
        let m_pt = packet[1]
        let marker = (m_pt & 0x80) != 0
        let cc = Int(v_p_x_cc & 0x0F)
        var headerLength = 12 + cc * 4
        
        // 扩展头支持
        if (v_p_x_cc & 0x10) != 0 {
            if packet.count >= headerLength + 4 {
                let extLen = (Int(packet[headerLength + 2]) << 8) | Int(packet[headerLength + 3])
                headerLength += 4 + extLen * 4
            }
        }
        
        guard packet.count > headerLength else { return }
        let payload = packet.subdata(in: headerLength ..< packet.count)
        guard !payload.isEmpty else { return }
        
        let firstByte = payload[0]
        let nalType = firstByte & 0x1F
        
        if nalType >= 1 && nalType <= 23 {
            // 单一 NAL 单元数据包
            handleCompleteNal(payload)
            if marker {
                flushFrame()
            }
        } else if nalType == 24 {
            // STAP-A 聚合包 (可能包含 SPS + PPS)
            var offset = 1
            while offset + 2 <= payload.count {
                let size = (Int(payload[offset]) << 8) | Int(payload[offset + 1])
                offset += 2
                if offset + size <= payload.count {
                    let nal = payload.subdata(in: offset ..< (offset + size))
                    offset += size
                    handleCompleteNal(nal)
                }
            }
            if marker {
                flushFrame()
            }
        } else if nalType == 28 {
            // FU-A 分片单元
            guard payload.count >= 2 else { return }
            let fuIndicator = payload[0]
            let fuHeader = payload[1]
            let isStart = (fuHeader & 0x80) != 0
            let isEnd = (fuHeader & 0x40) != 0
            let originalNalType = fuHeader & 0x1F
            let reconstructedHeader = (fuIndicator & 0xE0) | originalNalType
            let slice = payload.subdata(in: 2 ..< payload.count)
            
            if isStart {
                currentFuBuffer = Data([reconstructedHeader])
                currentFuBuffer.append(slice)
            } else {
                currentFuBuffer.append(slice)
            }
            
            if isEnd {
                let completeNal = currentFuBuffer
                currentFuBuffer.removeAll(keepingCapacity: true)
                handleCompleteNal(completeNal)
                if marker {
                    flushFrame()
                }
            }
        }
    }
    
    private func handleCompleteNal(_ nal: Data) {
        guard !nal.isEmpty else { return }
        let nalType = nal[0] & 0x1F
        
        if nalType == 7 { // SPS
            self.spsData = nal
            if let pps = ppsData {
                updateFormatDescription(sps: nal, pps: pps)
            }
        } else if nalType == 8 { // PPS
            self.ppsData = nal
            if let sps = spsData {
                updateFormatDescription(sps: sps, pps: nal)
            }
        } else if nalType == 1 || nalType == 5 { // 视频主帧切片 (非 IDR / IDR 关键帧)
            currentNalUnits.append(nal)
        }
    }
    
    private func updateFormatDescription(sps: Data, pps: Data) {
        var formatDesc: CMVideoFormatDescription?
        
        sps.withUnsafeBytes { spsBuffer in
            pps.withUnsafeBytes { ppsBuffer in
                guard let spsPointer = spsBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self),
                      let ppsPointer = ppsBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
                
                var pointers: [UnsafePointer<UInt8>] = [spsPointer, ppsPointer]
                var sizes: [Int] = [sps.count, pps.count]
                
                let status = CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault,
                    parameterSetCount: 2,
                    parameterSetPointers: &pointers,
                    parameterSetSizes: &sizes,
                    nalUnitHeaderLength: 4,
                    formatDescriptionOut: &formatDesc
                )
                
                if status == noErr, let desc = formatDesc {
                    self.formatDescription = desc
                    let dimensions = CMVideoFormatDescriptionGetDimensions(desc)
                    S02Logger.shared.log("★ H.264 硬件解码器已匹配参数集: 分辨率 \(dimensions.width)x\(dimensions.height)", tag: "NativeRTSP")
                }
            }
        }
    }
    
    private func flushFrame() {
        guard !currentNalUnits.isEmpty else { return }
        let nalsToRender = currentNalUnits
        currentNalUnits.removeAll(keepingCapacity: true)
        
        guard let format = self.formatDescription else {
            // 参数集尚未就绪，暂存等待
            return
        }
        
        // 组装 AVCC 格式数据 (4 字节大端长度前缀)
        let totalSize = nalsToRender.reduce(0) { $0 + 4 + $1.count }
        var avcc = Data(capacity: totalSize)
        for nal in nalsToRender {
            var len = UInt32(nal.count).bigEndian
            avcc.append(Data(bytes: &len, count: 4))
            avcc.append(nal)
        }
        
        var blockBuffer: CMBlockBuffer?
        let blockStatus = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: avcc.count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: avcc.count,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard blockStatus == kCMBlockBufferNoErr, let block = blockBuffer else { return }
        
        avcc.withUnsafeBytes { raw in
            if let ptr = raw.baseAddress {
                CMBlockBufferReplaceDataBytes(with: ptr, blockBuffer: block, offsetIntoDestination: 0, dataLength: avcc.count)
            }
        }
        
        var sampleBuffer: CMSampleBuffer?
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 30),
            presentationTimeStamp: CMTime(seconds: CACurrentMediaTime(), preferredTimescale: 90000),
            decodeTimeStamp: .invalid
        )
        var sampleSize = avcc.count
        let sampleStatus = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: block,
            formatDescription: format,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        )
        guard sampleStatus == noErr, let sample = sampleBuffer else { return }
        
        // 标记立即渲染，跳过系统缓冲区积压，达成极致低延迟
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true) {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(
                dict,
                Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
            )
        }
        
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            
            if self.videoView.sampleBufferLayer.status == .failed {
                self.videoView.sampleBufferLayer.flush()
            }
            self.videoView.sampleBufferLayer.enqueue(sample)
            
            if self.firstFrameLatencyMs == nil, let start = self.playStartTime {
                let lat = max(1, Int(Date().timeIntervalSince(start) * 1000))
                self.firstFrameLatencyMs = lat
                self.currentState = .playing(url: self.currentUrl, latencyMs: lat)
                S02Logger.shared.log("★ RTSP 首帧画面成功硬解渲染！首帧耗时: \(lat) ms", tag: "NativeRTSP")
            }
        }
    }
}
