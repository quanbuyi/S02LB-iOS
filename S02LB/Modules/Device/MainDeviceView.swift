import SwiftUI

/// S02LB 智能眼镜主控制台视图
public struct MainDeviceView: View {
    @StateObject private var viewModel = MainDeviceViewModel()
    @ObservedObject private var ble = BleManager.shared
    @ObservedObject private var coordinator = WifiRtspCoordinator.shared
    @ObservedObject private var hotspot = HotspotManager.shared
    
    public init() {}
    
    public var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 16) {
                    // 1. 顶部连接状态栏
                    connectionStatusBar
                    
                    // 2. 扫描与可用设备列表 (未连接时显示)
                    if !ble.isConnected {
                        deviceScanSection
                    }
                    
                    // 3. 设备实时状态看板
                    if ble.isConnected {
                        deviceStatusSection
                    }
                    
                    // 4. Wi-Fi AP 自动连接与 RTSP 控制面板 (Phase 2 新增)
                    if ble.isConnected {
                        wifiRtspSection
                        RtspPreviewView()
                        FtpMediaView()
                    }
                    
                    // 5. 命令控制面板
                    commandSection
                    
                    // 6. 交互日志监控区 (受宏与配置开关控制)
                    #if ENABLE_INTERACTION_LOG
                    if AppConfig.enableInteractionLog {
                        logSection
                    }
                    #endif
                }
                .padding()
            }
            .navigationTitle("S02LB 控制台")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: {
                        viewModel.toggleScan()
                    }) {
                        HStack(spacing: 4) {
                            if ble.isScanning {
                                ProgressView()
                                    .progressViewStyle(CircularProgressViewStyle(tint: .blue))
                                    .scaleEffect(0.8)
                            }
                            Text(ble.isScanning ? "停止" : "扫描")
                        }
                    }
                }
            }
            .alert(isPresented: $viewModel.showAlert) {
                Alert(title: Text("提示"), message: Text(viewModel.alertMessage ?? ""), dismissButton: .default(Text("确定")))
            }
            .sheet(isPresented: $viewModel.showFanDialog) {
                fanSelectionSheet
            }
            .sheet(isPresented: $viewModel.showWifiPwDialog) {
                wifiPasswordSheet
            }
        }
    }
    
    // MARK: - 顶部连接状态条
    private var connectionStatusBar: some View {
        HStack {
            Circle()
                .fill(ble.isConnected ? Color.green : Color.red)
                .frame(width: 12, height: 12)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(ble.isConnected ? "已连接: \(ble.connectedDevice?.name ?? "眼镜设备")" : (ble.isScanning ? "正在扫描设备..." : "未连接"))
                    .font(.headline)
                
                if ble.isConnected {
                    Text(ble.servicesSummary)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
            
            Spacer()
            
            if ble.isConnected {
                Button(action: {
                    viewModel.disconnect()
                }) {
                    Text("断开")
                        .foregroundColor(.red)
                        .font(.subheadline)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Color.red.opacity(0.1))
                        .cornerRadius(6)
                }
            }
        }
        .padding()
        .background(Color(UIColor.secondarySystemBackground))
        .cornerRadius(12)
    }
    
    // MARK: - 扫描设备列表
    private var deviceScanSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("▸ 发现的设备 (\(ble.discoveredDevices.count))")
                .font(.subheadline)
                .foregroundColor(.secondary)
            
            if ble.discoveredDevices.isEmpty {
                HStack {
                    Spacer()
                    Text(ble.isScanning ? "正在搜索 CAM- / G1- / S02LB 广播..." : "点击右上角「扫描」搜索眼镜")
                        .font(.footnote)
                        .foregroundColor(.gray)
                        .padding(.vertical, 20)
                    Spacer()
                }
                .background(Color(UIColor.tertiarySystemBackground))
                .cornerRadius(8)
            } else {
                ForEach(ble.discoveredDevices) { dev in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(dev.name)
                                .font(.body)
                                .fontWeight(.medium)
                            Text(dev.peripheral.identifier.uuidString)
                                .font(.caption2)
                                .foregroundColor(.gray)
                        }
                        
                        Spacer()
                        
                        Text("\(dev.rssi) dBm")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        
                        Button("连接") {
                            viewModel.connect(device: dev)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                    .padding(10)
                    .background(Color(UIColor.secondarySystemBackground))
                    .cornerRadius(8)
                }
            }
        }
    }
    
    // MARK: - 设备状态展示
    private var deviceStatusSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("▸ 设备实时状态")
                .font(.subheadline)
                .foregroundColor(.secondary)
            
            let rep = ble.latestReport ?? S02LbReport(rawJson: "{}")
            
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                statusTile(title: "电量", value: rep.soc == "-" ? "-" : "\(rep.soc)% \(rep.isCharging ? "(充电中)" : "")", icon: "battery.100")
                statusTile(title: "工作状态", value: rep.isRecording ? "🔴 录像中" : "⚪ 待机", icon: "waveform")
                statusTile(title: "SD 容量", value: "\(rep.size) GB (余 \(rep.free) GB)", icon: "externaldrive")
                statusTile(title: "风扇档位", value: fanDescription(rep.fan), icon: "fanblades")
                statusTile(title: "蜂鸣器", value: rep.isBuzzerOn ? "开启" : "关闭", icon: "speaker.wave.2")
                statusTile(title: "录像分段", value: rep.record == "0" || rep.record == "N" ? "一直录像" : "\(rep.record) 分钟", icon: "timer")
                statusTile(title: "固件版本", value: rep.version, icon: "gearshape")
                statusTile(title: "WiFi 热点", value: rep.wifi.isEmpty || rep.wifi == "-" ? "已关闭" : rep.wifi, icon: "wifi")
            }
        }
    }
    
    // MARK: - Wi-Fi AP 与 RTSP 控制看板 (Phase 2)
    private var wifiRtspSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("▸ 眼镜 Wi-Fi 与推流链路 (Phase 2)")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                Spacer()
                Text(coordinator.phase.rawValue)
                    .font(.caption)
                    .fontWeight(.bold)
                    .foregroundColor(coordinator.isError ? .red : .blue)
            }
            
            VStack(alignment: .leading, spacing: 8) {
                // 状态指示条
                HStack(spacing: 8) {
                    if hotspot.isTargetHotspotConnected {
                        badge(title: "眼镜 Wi-Fi", active: true, activeColor: .green)
                    } else if hotspot.isOtherWifiConnected {
                        badge(title: "其它 Wi-Fi", active: true, activeColor: .orange)
                    } else {
                        badge(title: "Wi-Fi 未连", active: false)
                    }
                    badge(title: "FTP (21)", active: coordinator.isFtpReady, activeColor: .green)
                    badge(title: "RTSP (554)", active: coordinator.isRtspReady, activeColor: .green)
                }
                
                // 状态机实时提示
                Text(coordinator.statusText)
                    .font(.caption)
                    .foregroundColor(coordinator.isError ? .red : .primary)
                    .lineLimit(2)
                
                // 目标热点信息与辅助按钮 (支持一键复制密码与跳转系统设置)
                if !coordinator.currentTargetSSID.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 5) {
                                    Circle()
                                        .fill(coordinator.isHotspotHardwareReady ? Color.green : Color.orange)
                                        .frame(width: 8, height: 8)
                                    Text("热点名称: \(coordinator.currentTargetSSID)")
                                        .font(.subheadline)
                                        .fontWeight(.bold)
                                }
                                Text("连接密码: \(coordinator.currentTargetPassword)")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            Button(action: {
                                viewModel.copyWifiPassword()
                            }) {
                                HStack(spacing: 3) {
                                    Image(systemName: "doc.on.doc")
                                    Text("复制密码")
                                }
                                .font(.caption)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(Color.blue.opacity(0.12))
                                .cornerRadius(6)
                            }
                        }
                        
                        // 醒目的前往系统 Wi-Fi 按钮
                        Button(action: {
                            viewModel.openSystemWifiSettings()
                        }) {
                            HStack {
                                Image(systemName: "wifi")
                                if hotspot.isTargetHotspotConnected {
                                    Text("已连入眼镜热点【\(coordinator.currentTargetSSID)】(IP: \(hotspot.currentWifiIP ?? "-"))")
                                        .fontWeight(.medium)
                                } else if hotspot.isOtherWifiConnected {
                                    Text("⚠️ 当前连接其它 Wi-Fi，点击切换至【\(coordinator.currentTargetSSID)】")
                                        .fontWeight(.medium)
                                } else {
                                    Text("前往系统设置连接【\(coordinator.currentTargetSSID)】")
                                        .fontWeight(.medium)
                                }
                            }
                            .font(.caption)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(hotspot.isTargetHotspotConnected ? Color.green.opacity(0.15) : Color.orange.opacity(0.2))
                            .foregroundColor(hotspot.isTargetHotspotConnected ? .green : .orange)
                            .cornerRadius(6)
                        }
                        
                        if coordinator.isHotspotHardwareReady && !hotspot.isTargetHotspotConnected {
                            if hotspot.isOtherWifiConnected {
                                Text("⚠️ 手机当前正连接其它 Wi-Fi (IP: \(hotspot.currentWifiIP ?? "-"))，未连接眼镜热点！已自动复制密码 \(coordinator.currentTargetPassword)，请点击上方按钮切换到【\(coordinator.currentTargetSSID)】")
                                    .font(.system(size: 11))
                                    .foregroundColor(.orange)
                            } else {
                                Text("💡 眼镜热点已就绪。若 iOS 未自动弹出加入窗口，请点击上方橙色按钮前往系统 Wi-Fi 列表选择【\(coordinator.currentTargetSSID)】连接")
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                    .padding(10)
                    .background(Color(UIColor.tertiarySystemBackground))
                    .cornerRadius(10)
                }
                
                // RTSP 地址输入
                HStack {
                    Text("流地址:")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    TextField("RTSP URL", text: $viewModel.customRtspUrlInput)
                        .font(.caption)
                        .textFieldStyle(.roundedBorder)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                }
                
                // 控制按钮行
                HStack(spacing: 10) {
                    Button(action: {
                        viewModel.startWifiAp()
                    }) {
                        Label("开启热点", systemImage: "wifi")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    
                    Button(action: {
                        viewModel.stopWifiAp()
                    }) {
                        Label("关闭热点", systemImage: "wifi.slash")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                
                HStack(spacing: 10) {
                    Button(action: {
                        viewModel.startRtsp()
                    }) {
                        Label("启动推流", systemImage: "play.circle.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    
                    Button(action: {
                        viewModel.stopRtsp()
                    }) {
                        Label("停止推流", systemImage: "stop.circle.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)
                    .controlSize(.small)
                }
            }
            .padding(12)
            .background(Color(UIColor.secondarySystemBackground))
            .cornerRadius(10)
        }
    }
    
    private func badge(title: String, active: Bool, activeColor: Color = .green) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(active ? activeColor : Color.gray.opacity(0.5))
                .frame(width: 8, height: 8)
            Text(title)
                .font(.caption2)
                .foregroundColor(active ? .primary : .secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color(UIColor.tertiarySystemBackground))
        .cornerRadius(6)
    }
    
    private func statusTile(title: String, value: String, icon: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundColor(.blue)
                .frame(width: 20)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Text(value)
                    .font(.footnote)
                    .fontWeight(.semibold)
                    .lineLimit(1)
            }
            Spacer()
        }
        .padding(8)
        .background(Color(UIColor.secondarySystemBackground))
        .cornerRadius(8)
    }
    
    private func fanDescription(_ fan: String) -> String {
        switch fan {
        case "0": return "关闭"
        case "1": return "1 档"
        case "2": return "2 档"
        case "3": return "3 档"
        default:  return fan
        }
    }
    
    // MARK: - 命令控制面板
    private var commandSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            // 拍照与录像
            commandGroup(title: "拍照录像") {
                HStack {
                    cmdButton("PHOTO 拍照", cmd: .photo)
                    cmdButton("START_REC 开始录像", cmd: .startRec)
                }
                cmdButton("STOP_REC 停止录像", cmd: .stopRec)
            }
            
            // SD 卡操作
            commandGroup(title: "存储卡") {
                cmdButton("SD_FMT 格式化SD卡", cmd: .sdFormat, role: .destructive)
            }
            
            // 系统与外设
            commandGroup(title: "硬件控制") {
                HStack {
                    cmdButton("SET_FAN 调节风扇", action: { viewModel.showFanDialog = true })
                    cmdButton("LED_TEST LED测试", cmd: .ledTest)
                }
                HStack {
                    cmdButton("蜂鸣器 开", cmd: .setBuzzOn)
                    cmdButton("蜂鸣器 关", cmd: .setBuzzOff)
                }
                HStack {
                    cmdButton("录像 3分钟", cmd: .setRec3Min)
                    cmdButton("录像 5分钟", cmd: .setRec5Min)
                    cmdButton("录像 一直", cmd: .setRecAlways)
                }
                cmdButton("PWR_OFF 关机", cmd: .powerOff, role: .destructive)
            }
            
            // 系统配置
            commandGroup(title: "参数配置") {
                cmdButton("同步手机时间 (当前)", action: { viewModel.syncCurrentTime() })
                cmdButton("设置 WiFi 密码", action: { viewModel.showWifiPwDialog = true })
            }
        }
    }
    
    private func commandGroup<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("▸ \(title)")
                .font(.subheadline)
                .foregroundColor(.secondary)
            content()
        }
    }
    
    private func cmdButton(_ title: String, cmd: S02LbProtocol.Command, role: ButtonRole? = nil) -> some View {
        cmdButton(title, role: role) {
            viewModel.sendCommand(cmd)
        }
    }
    
    private func cmdButton(_ title: String, role: ButtonRole? = nil, action: @escaping () -> Void) -> some View {
        Button(role: role, action: action) {
            Text(title)
                .font(.footnote)
                .fontWeight(.medium)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
        }
        .buttonStyle(.bordered)
        .disabled(!ble.isConnected)
    }
    
    // MARK: - 日志监视区
    private var logSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("▸ 交互日志 (\(ble.logMessages.count))")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                Spacer()
                Button(action: {
                    viewModel.copyDiagnosticsSummary()
                }) {
                    HStack(spacing: 3) {
                        Image(systemName: "doc.on.doc")
                        Text("复制精简日志(QQ)")
                            .fontWeight(.medium)
                    }
                    .font(.caption2)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.blue.opacity(0.15))
                    .foregroundColor(.blue)
                    .cornerRadius(4)
                }
                
                Button(action: {
                    viewModel.copyAllLogs()
                }) {
                    Text("全部")
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 4)
                        .background(Color.secondary.opacity(0.12))
                        .cornerRadius(4)
                }
                
                Button(action: {
                    ble.clearLogs()
                }) {
                    Text("清空")
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 4)
                        .background(Color.red.opacity(0.12))
                        .foregroundColor(.red)
                        .cornerRadius(4)
                }
            }
            
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(ble.logMessages.enumerated()), id: \.offset) { index, msg in
                            Text(msg)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(.primary)
                                .id(index)
                        }
                    }
                    .padding(8)
                }
                .frame(height: 160)
                .background(Color(UIColor.secondarySystemBackground))
                .cornerRadius(8)
                .onChange(of: ble.logMessages.count) { _ in
                    if let lastIndex = ble.logMessages.indices.last {
                        proxy.scrollTo(lastIndex, anchor: .bottom)
                    }
                }
            }
        }
    }
    
    // MARK: - 风扇调节弹窗
    private var fanSelectionSheet: some View {
        NavigationView {
            List {
                let current = ble.latestReport?.fanLevel ?? 0
                fanRow(title: "关闭风扇 (0)", level: 0, current: current)
                fanRow(title: "风扇一档 (1)", level: 1, current: current)
                fanRow(title: "风扇二档 (2)", level: 2, current: current)
                fanRow(title: "风扇三档 (3)", level: 3, current: current)
            }
            .navigationTitle("调节风扇档位")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") { viewModel.showFanDialog = false }
                }
            }
        }
    }
    
    private func fanRow(title: String, level: Int, current: Int) -> some View {
        Button(action: {
            viewModel.setFanLevel(level)
            viewModel.showFanDialog = false
        }) {
            HStack {
                Text(title)
                Spacer()
                if level == current {
                    Image(systemName: "checkmark")
                        .foregroundColor(.blue)
                }
            }
        }
    }
    
    // MARK: - WiFi 密码弹窗
    private var wifiPasswordSheet: some View {
        NavigationView {
            Form {
                Section(header: Text("输入新密码 (8~16 位)")) {
                    TextField("WiFi 密码", text: $viewModel.wifiPasswordInput)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                }
                Section {
                    Button("确定设置") {
                        viewModel.submitWifiPassword()
                        viewModel.showWifiPwDialog = false
                    }
                    .disabled(viewModel.wifiPasswordInput.count < 8 || viewModel.wifiPasswordInput.count > 16)
                }
            }
            .navigationTitle("设置 WiFi 密码")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("取消") { viewModel.showWifiPwDialog = false }
                }
            }
        }
    }
}
