//
//  AirVolumeService.swift
//  Air Volume
//
//  Created by Codex on behalf of Francesco.
//

import Foundation
import Combine
import AppKit
import SwiftUI
import QuartzCore
import Darwin

private let discoverPort: UInt16 = 4210
private let discoverAddress = "255.255.255.255"
private let discoverInterval: TimeInterval = 7.0
private let discoverJitter: ClosedRange<Double> = -0.3...0.3
private let heartbeatInterval: TimeInterval = 5.0
private let watchdogTimeout: TimeInterval = 12.0
private let retryMin: TimeInterval = 0.05
private let retryMax: TimeInterval = 1.0
private let retryJitter: ClosedRange<Double> = -0.05...0.05
private let staleTargetTTL: TimeInterval = 20.0
private let setOnDelta: Double = 0.5

@MainActor
final class AirVolumeService: NSObject, ObservableObject {
    struct Target: Equatable {
        let ip: String
        let wsPort: Int
        let name: String?
        let path: String?
        let lastSeen: Date
    }

    enum ConnectionState: CustomStringConvertible {
        case idle
        case discovering
        case connecting(String)
        case connected(String)
        case waitingForTarget
        case reconnecting(TimeInterval)
        case error(String)

        var description: String {
            switch self {
            case .idle: return "In attesa"
            case .discovering: return "Ricerca dispositivi..."
            case .connecting(let target): return "Connessione a \(target)"
            case .connected(let target): return "Connesso a \(target)"
            case .waitingForTarget: return "Nessun device disponibile"
            case .reconnecting(let delay): return String(format: "Riconnessione tra %.2fs", delay)
            case .error(let reason): return "Errore: \(reason)"
            }
        }
    }

    @Published private(set) var state: ConnectionState = .idle
    @Published private(set) var logs: [String] = []
    @Published private(set) var currentTarget: Target?
    @Published private(set) var lastVolumePercent: Int?

    private let volumeController = VolumeController()
    private let overlay = OverlayNotificationCenter.shared

    private let env = ProcessInfo.processInfo.environment
    private lazy var forcedIP: String? = env["AIRVOL_IP"].flatMap { $0.isEmpty ? nil : $0 }
    private lazy var forcedPort: Int? = env["AIRVOL_WS_PORT"].flatMap { Int($0) }
    private lazy var forcedName: String? = env["AIRVOL_NAME"].flatMap { $0.isEmpty ? nil : $0 }

    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 120
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    private var discovery: UdpDiscovery?
    private var loopTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var watchdogTask: Task<Void, Never>?
    private var webSocketTask: URLSessionWebSocketTask?
    private var lastReceiveDate = Date.distantPast

    override init() {
        super.init()
        start()
    }

    func start() {
        guard discovery == nil else { return }
        state = forcedIP != nil ? .connecting(forcedIP ?? "target") : .discovering
        let discovery = UdpDiscovery()
        self.discovery = discovery
        discovery.delegate = self
        discovery.start()
        log("[DISCOVERY] avviato su UDP *:\(discoverPort) (broadcast abilitato)")
        loopTask = Task { [weak self] in
            await self?.runLoop()
        }
        if forcedIP != nil {
            overlay.show(title: "Connessione forzata", subtitle: forcedIP)
        }
    }

    func stop() {
        loopTask?.cancel()
        heartbeatTask?.cancel()
        watchdogTask?.cancel()
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        discovery?.stop()
    }

    private func runLoop() async {
        var retryDelay = retryMin
        while !Task.isCancelled {
            if Task.isCancelled { break }
            guard let target = pickTarget() else {
                state = forcedIP != nil ? .connecting(forcedIP ?? "target") : .waitingForTarget
                try? await Task.sleep(nanoseconds: 500_000_000)
                continue
            }

            if isTargetStale(target) && forcedIP == nil {
                state = .waitingForTarget
                try? await Task.sleep(nanoseconds: 500_000_000)
                continue
            }

            let urls = buildWebSocketURLs(from: target)
            var connected = false
            for url in urls {
                if Task.isCancelled { break }
                state = .connecting(url.absoluteString)
                log("[MAIN] connettendo a \(url.absoluteString) ...")
                overlay.show(title: "Connessione", subtitle: displayLabel(for: target))
                let ok = await connect(to: url, target: target)
                if Task.isCancelled { break }
                if ok {
                    retryDelay = retryMin
                    connected = true
                    break
                }
            }
            if Task.isCancelled { break }
            if connected {
                continue
            }
            let jitter = Double.random(in: retryJitter)
            let sleepTime = max(0.0, retryDelay + jitter)
            state = .reconnecting(sleepTime)
            log(String(format: "[MAIN] Connessione caduta, riprovo tra %.3fs", sleepTime))
            try? await Task.sleep(nanoseconds: UInt64(sleepTime * 1_000_000_000))
            retryDelay = min(retryMax, max(retryMin, retryDelay * 1.5))
        }
    }

    private func pickTarget() -> Target? {
        if let forcedIP {
            let port = forcedPort ?? 81
            let forced = Target(ip: forcedIP, wsPort: port, name: forcedName, path: nil, lastSeen: .distantFuture)
            if currentTarget != forced {
                currentTarget = forced
            }
            return forced
        }
        return currentTarget
    }

    private func isTargetStale(_ target: Target) -> Bool {
        Date().timeIntervalSince(target.lastSeen) > staleTargetTTL
    }

    private func buildWebSocketURLs(from target: Target) -> [URL] {
        var ports: [Int] = []
        if let forcedPort { ports.append(forcedPort) }
        if !ports.contains(target.wsPort) { ports.append(target.wsPort) }

        var paths: [String] = []
        if let path = target.path, path.hasPrefix("/") { paths.append(path) }
        if !paths.contains("/ws") { paths.append("/ws") }
        if !paths.contains("/") { paths.append("/") }

        var urls: [URL] = []
        for port in ports {
            for path in paths {
                if let url = URL(string: "ws://\(target.ip):\(port)\(path)") {
                    urls.append(url)
                }
            }
        }
        return urls
    }

    private func connect(to url: URL, target: Target) async -> Bool {
        heartbeatTask?.cancel()
        watchdogTask?.cancel()
        webSocketTask?.cancel(with: .goingAway, reason: nil)

        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("http://airvol.local", forHTTPHeaderField: "Origin")
        request.setValue("permessage-deflate; client_max_window_bits", forHTTPHeaderField: "Sec-WebSocket-Extensions")
        let task = session.webSocketTask(with: request)
        webSocketTask = task
        lastReceiveDate = Date()
        task.resume()

        let receiveTask = Task.detached(priority: .userInitiated) { [weak self] () -> Bool in
            guard let self else { return false }
            while !Task.isCancelled {
                do {
                    let message = try await task.receive()
                    await self.handle(message: message)
                } catch {
                    await self.handleReceiveError(error)
                    return false
                }
                await self.updateLastReceive()
            }
            return false
        }

        heartbeatTask = Task.detached { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(heartbeatInterval * 1_000_000_000))
                if Task.isCancelled { break }
                do {
                    try await task.send(.string("{\"hb\":1}"))
                } catch {
                    await self.handleHeartbeatError(error)
                    break
                }
            }
        }

        watchdogTask = Task.detached { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if Task.isCancelled { break }
                await self.checkWatchdog()
            }
        }

        let connected = await receiveTask.value
        heartbeatTask?.cancel()
        watchdogTask?.cancel()
        heartbeatTask = nil
        watchdogTask = nil
        return connected
    }

    private func handle(message: URLSessionWebSocketTask.Message) async {
        lastReceiveDate = Date()
        switch message {
        case .data(let data):
            guard let string = String(data: data, encoding: .utf8) else { return }
            await handlePayload(string)
        case .string(let string):
            await handlePayload(string)
        @unknown default:
            break
        }
    }

    private func handlePayload(_ payload: String) async {
        guard let data = payload.data(using: .utf8) else { return }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        if let percent = parsePercent(from: json) {
            let clamped = clamp(percent)
            let volumeInt = Int(clamped.rounded())
            if volumeController.setVolumeIfNeeded(volumeInt, threshold: setOnDelta) {
                lastVolumePercent = volumeInt
                overlay.show(title: "Volume", subtitle: "\(volumeInt)%")
            }
        }
    }

    private func parsePercent(from json: [String: Any]) -> Double? {
        for key in ["percent", "pct", "volume_percent"] {
            if let value = json[key] as? Double { return value }
            if let string = json[key] as? String, let double = Double(string) { return double }
            if let intValue = json[key] as? Int { return Double(intValue) }
        }
        if let raw = json["raw"] {
            if let value = raw as? Double { return (value * 100.0) / 4095.0 }
            if let string = raw as? String, let double = Double(string) { return (double * 100.0) / 4095.0 }
        }
        return nil
    }

    private func clamp(_ value: Double) -> Double {
        min(100.0, max(0.0, value))
    }

    private func updateLastReceive() async {
        lastReceiveDate = Date()
    }

    private func checkWatchdog() async {
        let delta = Date().timeIntervalSince(lastReceiveDate)
        if delta > watchdogTimeout {
            log("[MAIN] Watchdog: nessun dato applicativo ricevuto da \(delta)s")
            webSocketTask?.cancel(with: .goingAway, reason: nil)
            heartbeatTask?.cancel()
            watchdogTask?.cancel()
        }
    }

    private func handleReceiveError(_ error: Error) async {
        log("[WS] errore: \(error.localizedDescription)")
        overlay.show(title: "Errore", subtitle: "WebSocket")
    }

    private func handleHeartbeatError(_ error: Error) async {
        log("[HB] errore invio heartbeat: \(error.localizedDescription)")
    }

    private func log(_ message: String) {
        let ts = tsString(Date())
        logs.append("\(ts) \(message)")
        if logs.count > 200 {
            logs.removeFirst(logs.count - 200)
        }
    }

    func copyLogsToPasteboard() {
        let joined = logs.joined(separator: "\n")
        guard !joined.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(joined, forType: .string)
        overlay.show(title: "Log copiati", subtitle: nil, systemImage: "doc.on.doc")
    }

    private func tsString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }

    private func displayLabel(for target: Target) -> String {
        target.name ?? "\(target.ip):\(target.wsPort)"
    }
}

extension AirVolumeService: UdpDiscoveryDelegate {
    func discovery(_ discovery: UdpDiscovery, didSelect target: AirVolumeService.Target) {
        if let forcedName, forcedName != (target.name ?? "") { return }
        if let forcedIP, forcedIP != target.ip { return }

        if let current = currentTarget,
           current.ip == target.ip,
           current.wsPort == target.wsPort {
            currentTarget = Target(ip: target.ip,
                                   wsPort: target.wsPort,
                                   name: target.name ?? current.name,
                                   path: target.path ?? current.path,
                                   lastSeen: Date())
            return
        }

        currentTarget = target
        switch state {
        case .connected, .connecting:
            break
        default:
            state = .discovering
        }
        overlay.show(title: "Device", subtitle: displayLabel(for: target))
        log("[DISCOVERY] target selezionato -> \(displayLabel(for: target))")
    }

    func discovery(_ discovery: UdpDiscovery, didLog message: String) {
        log(message)
    }
}

extension AirVolumeService: URLSessionWebSocketDelegate {
    nonisolated func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        Task { @MainActor in
            self.state = .connected(webSocketTask.currentRequest?.url?.absoluteString ?? "ws")
            self.log("[WS] connesso - on_open")
            self.overlay.show(title: "Connesso", subtitle: webSocketTask.currentRequest?.url?.host)
        }
    }

    nonisolated func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        Task { @MainActor in
            self.log("[WS] Chiuso: code=\(closeCode.rawValue)")
        }
    }
}

protocol UdpDiscoveryDelegate: AnyObject {
    func discovery(_ discovery: UdpDiscovery, didSelect target: AirVolumeService.Target)
    func discovery(_ discovery: UdpDiscovery, didLog message: String)
}

final class UdpDiscovery {
    weak var delegate: UdpDiscoveryDelegate?

    private var socketFD: Int32 = -1
    private var senderThread: Thread?
    private var receiverThread: Thread?
    private let lock = NSLock()
    private var shouldStop = false
    private let env = ProcessInfo.processInfo.environment
    private lazy var forcedIP: String? = env["AIRVOL_IP"].flatMap { $0.isEmpty ? nil : $0 }
    private lazy var forcedName: String? = env["AIRVOL_NAME"].flatMap { $0.isEmpty ? nil : $0 }

    func start() {
        lock.lock()
        defer { lock.unlock() }
        guard socketFD == -1 else { return }

        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else {
            let message = "[DISCOVERY] errore apertura socket: \(errnoDescription(errno))"
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.delegate?.discovery(self, didLog: message)
            }
            return
        }

        var broadcast: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &broadcast, socklen_t(MemoryLayout.size(ofValue: broadcast)))

        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout.size(ofValue: reuse)))
        #if os(macOS)
        setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &reuse, socklen_t(MemoryLayout.size(ofValue: reuse)))
        #endif

        var timeout = timeval(tv_sec: 1, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = discoverPort.bigEndian
        addr.sin_addr = in_addr(s_addr: in_addr_t(0))

        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }

        guard bindResult >= 0 else {
            let message = "[DISCOVERY] errore bind: \(errnoDescription(errno))"
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.delegate?.discovery(self, didLog: message)
            }
            close(fd)
            return
        }

        socketFD = fd
        shouldStop = false

        startThreads()
    }

    func stop() {
        lock.lock()
        shouldStop = true
        let fd = socketFD
        socketFD = -1
        lock.unlock()

        if fd >= 0 {
            shutdown(fd, SHUT_RDWR)
            close(fd)
        }

        senderThread?.cancel()
        receiverThread?.cancel()
        senderThread = nil
        receiverThread = nil
    }

    private func startThreads() {
        let sender = Thread { [weak self] in
            self?.sendLoop()
        }
        sender.name = "airvol.discovery.sender"
        sender.start()
        senderThread = sender

        let receiver = Thread { [weak self] in
            self?.receiveLoop()
        }
        receiver.name = "airvol.discovery.receiver"
        receiver.start()
        receiverThread = receiver
    }

    private func sendLoop() {
        guard let payload = try? JSONSerialization.data(withJSONObject: ["type": "discover", "service": "airvol"]) else {
            return
        }
        sendOnce(payload: payload)
        while !Thread.current.isCancelled {
            if isStopped { break }
            let delay = max(1.0, discoverInterval + Double.random(in: discoverJitter))
            sleepInterruptible(delay)
            if isStopped || Thread.current.isCancelled { break }
            sendOnce(payload: payload)
        }
    }

    private func sendOnce(payload: Data) {
        let fd = currentSocket
        guard fd >= 0 else { return }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = discoverPort.bigEndian
        addr.sin_addr.s_addr = inet_addr(discoverAddress)

        payload.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { ptr in
                    let sent = sendto(fd, base, buffer.count, 0, ptr, socklen_t(MemoryLayout<sockaddr_in>.size))
                    if sent < 0 {
                        let err = errnoDescription(errno)
                        DispatchQueue.main.async { [weak self] in
                            guard let self else { return }
                            self.delegate?.discovery(self, didLog: "[DISCOVERY] errore sendto: \(err)")
                        }
                    } else {
                        DispatchQueue.main.async { [weak self] in
                            guard let self else { return }
                            self.delegate?.discovery(self, didLog: "[DISCOVERY] discover inviato (\(sent) byte)")
                        }
                    }
                }
            }
        }
    }

    private func receiveLoop() {
        var buffer = [UInt8](repeating: 0, count: 4096)
        while !Thread.current.isCancelled {
            if isStopped { break }
            let fd = currentSocket
            guard fd >= 0 else { break }

        var sender = sockaddr_in()
        var senderLen = socklen_t(MemoryLayout<sockaddr_in>.size)
            let byteCount: ssize_t = buffer.withUnsafeMutableBytes { rawBuffer in
                guard let baseAddress = rawBuffer.baseAddress else { return -1 }
                return withUnsafeMutablePointer(to: &sender) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { ptr in
                        recvfrom(fd, baseAddress, rawBuffer.count, 0, ptr, &senderLen)
                    }
                }
            }

            if byteCount > 0 {
                let length = Int(byteCount)
                let data = Data(buffer[..<length])
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.delegate?.discovery(self, didLog: "[DISCOVERY] announce ricevuto (\(length) byte)")
                }
                guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    if let payload = String(data: data, encoding: .utf8) {
                        DispatchQueue.main.async { [weak self] in
                            guard let self else { return }
                            self.delegate?.discovery(self, didLog: "[DISCOVERY] payload ignorato: \(payload)")
                        }
                    }
                    continue
                }
                processPacket(json: json, sender: sender)
            } else if byteCount == 0 {
                continue
            } else {
                let err = errno
                if err == EAGAIN || err == EWOULDBLOCK || err == EINTR {
                    continue
                }
                if isStopped { break }
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.delegate?.discovery(self, didLog: "[DISCOVERY] errore recvfrom: \(errnoDescription(err))")
                }
                sleepInterruptible(0.1)
            }
        }
    }

    private func processPacket(json: [String: Any], sender: sockaddr_in) {
        guard json["service"] as? String == "airvol" else { return }

        let messageType = (json["type"] as? String)?.lowercased()

        if messageType == nil {
            logDebug("payload senza type", json: json)
            return
        }

        if messageType == "discover" {
            return
        }

        guard messageType == "announce" || messageType == "response" else {
            logDebug("type non gestito (\(messageType ?? "nil"))", json: json)
            return
        }

        let ip: String
        if let explicitIP = json["ip"] as? String, !explicitIP.isEmpty {
            ip = explicitIP
        } else {
            var addr = sender.sin_addr
            var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            let derivedIP: String? = buffer.withUnsafeMutableBufferPointer { ptr in
                guard let base = ptr.baseAddress else { return nil }
                guard inet_ntop(AF_INET, &addr, base, socklen_t(INET_ADDRSTRLEN)) != nil else { return nil }
                return String(cString: base)
            }
            guard let resolved = derivedIP else { return }
            ip = resolved
        }

        let wsPortValue = json["ws_port"] ?? json["wsPort"] ?? json["port"]
        guard let wsPort = parsePort(wsPortValue) else {
            logDebug("announce senza ws_port", json: json)
            return
        }

        let name = (json["name"] ?? json["device_name"]) as? String
        if let forcedName, (name ?? "") != forcedName {
            return
        }
        if let forcedIP, ip != forcedIP {
            return
        }

        let path = (json["ws_path"] ?? json["path"]) as? String

        let target = AirVolumeService.Target(ip: ip, wsPort: wsPort, name: name, path: path?.hasPrefix("/") == true ? path : nil, lastSeen: Date())
        logDebug("announce parsed", json: json)
        DispatchQueue.main.async { [weak self] in
            guard let self, let delegate = self.delegate else { return }
            delegate.discovery(self, didSelect: target)
        }
    }

    private func logDebug(_ prefix: String, json: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]),
              let string = String(data: data, encoding: .utf8) else {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.delegate?.discovery(self, didLog: "[DISCOVERY] \(prefix)")
            }
            return
        }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.delegate?.discovery(self, didLog: "[DISCOVERY] \(prefix): \(string)")
        }
    }

    private func parsePort(_ value: Any?) -> Int? {
        if let intValue = value as? Int, intValue > 0 {
            return intValue
        }
        if let number = value as? NSNumber {
            let port = number.intValue
            return port > 0 ? port : nil
        }
        if let stringValue = value as? String {
            let trimmed = stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            if let intValue = Int(trimmed), intValue > 0 {
                return intValue
            }
            if let doubleValue = Double(trimmed) {
                let rounded = Int(doubleValue.rounded())
                return rounded > 0 ? rounded : nil
            }
        }
        return nil
    }

    private var isStopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return shouldStop || socketFD < 0
    }

    private var currentSocket: Int32 {
        lock.lock()
        defer { lock.unlock() }
        return socketFD
    }

    private func sleepInterruptible(_ interval: TimeInterval) {
        guard interval > 0 else { return }
        var remaining = interval
        let slice = 0.2
        while remaining > 0 {
            if isStopped || Thread.current.isCancelled { break }
            let duration = min(slice, remaining)
            Thread.sleep(forTimeInterval: duration)
            remaining -= duration
        }
    }

    private func errnoDescription(_ code: Int32) -> String {
        if let cString = strerror(code) {
            let description = String(cString: cString)
            return "\(code) (\(description))"
        }
        return "\(code)"
    }
}

final class VolumeController {
    private var lastVolume: Int?
    private let lock = NSLock()

    func setVolumeIfNeeded(_ value: Int, threshold: Double) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let clamped = max(0, min(100, value))
        if let last = lastVolume, abs(Double(last) - Double(clamped)) < threshold {
            return false
        }
        setSystemVolume(clamped)
        lastVolume = clamped
        return true
    }

    private func setSystemVolume(_ value: Int) {
        let script = "set volume output volume \(value)"
        let process = Process()
        process.launchPath = "/usr/bin/osascript"
        process.arguments = ["-e", script]
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            print("[ERR] impossibile impostare il volume: \(error)")
        }
    }
}

@MainActor
final class OverlayNotificationCenter {
    static let shared = OverlayNotificationCenter()

    private let model = OverlayNotificationModel()
    private var window: NSPanel?
    private var hideWorkItem: DispatchWorkItem?
    // macOS < 26 keeps the classic frozen glass; 26+ adopts liquid glass styling
    private let glassStyle: GlassBackground.Style

    private init() {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        glassStyle = version.majorVersion >= 26 ? .liquid : .frozen
    }

    func show(title: String, subtitle: String? = nil, systemImage: String? = nil) {
        ensureWindow()
        guard let window else { return }

        model.update(title: title, subtitle: subtitle, systemImage: systemImage)
        position(window: window)

        let shouldAnimate = !(window.isVisible && window.alphaValue > 0.95)
        window.orderFrontRegardless()

        if shouldAnimate {
            window.alphaValue = 0
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                window.animator().alphaValue = 1
            }
        }

        scheduleHide(after: 2.5)
    }

    private func ensureWindow() {
        guard window == nil else { return }
        let panel = makeWindow()
        let view = OverlayNotificationView(model: model, style: glassStyle)
        let hosting = NSHostingView(rootView: view)
        hosting.translatesAutoresizingMaskIntoConstraints = false
        hosting.frame = NSRect(origin: .zero, size: OverlayNotificationView.preferredSize)
        panel.contentView = hosting
        panel.setContentSize(OverlayNotificationView.preferredSize)
        panel.alphaValue = 0
        window = panel
        position(window: panel)
    }

    private func scheduleHide(after delay: TimeInterval) {
        hideWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.dismiss()
        }
        hideWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func dismiss() {
        guard let window, window.isVisible else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            window.animator().alphaValue = 0
        } completionHandler: {
            window.orderOut(nil)
        }
    }

    private func makeWindow() -> NSPanel {
        let panel = NSPanel(contentRect: .zero,
                            styleMask: [.nonactivatingPanel, .borderless],
                            backing: .buffered,
                            defer: true)
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        panel.isMovable = false
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.hasShadow = false
        panel.backgroundColor = .clear
        return panel
    }

    private func position(window: NSPanel) {
        guard let screen = NSScreen.main else { return }
        let size = window.frame.size
        let originX = screen.frame.midX - size.width / 2
        let padding: CGFloat = 120
        let originY = screen.frame.minY + padding
        window.setFrameOrigin(NSPoint(x: originX, y: originY))
    }
}

@MainActor
final class OverlayNotificationModel: ObservableObject {
    struct Content: Equatable {
        var title: String
        var subtitle: String?
        var systemImage: String?
    }

    @Published private(set) var content = Content(title: "", subtitle: nil, systemImage: nil)

    func update(title: String, subtitle: String?, systemImage: String?) {
        let newContent = Content(title: title, subtitle: subtitle, systemImage: systemImage)
        withAnimation(.easeInOut(duration: 0.12)) {
            content = newContent
        }
    }
}

struct OverlayNotificationView: View {
    @ObservedObject var model: OverlayNotificationModel
    let style: GlassBackground.Style

    static let preferredSize = NSSize(width: 220, height: 220)

    var body: some View {
        let content = model.content

        return ZStack {
            GlassBackground(style: style)
                .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                .overlay(overlayGradient)
                .overlay(
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .stroke(borderColor, lineWidth: style == .liquid ? 0.8 : 1.0)
                )
                .shadow(color: shadowColor, radius: style == .liquid ? 18 : 22, y: 12)

            VStack(spacing: 10) {
                if let symbol = content.systemImage {
                    Image(systemName: symbol)
                        .font(.system(size: 48, weight: .semibold))
                        .foregroundColor(symbolColor)
                        .symbolRenderingMode(.hierarchical)
                }

                Text(content.title)
                    .font(.system(size: 18, weight: .medium, design: .rounded))
                    .foregroundColor(primaryTextColor)

                if let subtitle = content.subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 15, weight: .regular, design: .rounded))
                        .foregroundColor(secondaryTextColor)
                }
            }
            .multilineTextAlignment(.center)
            .padding(.horizontal, 24)
        }
        .frame(width: Self.preferredSize.width, height: Self.preferredSize.height)
        .accessibilityElement(children: .combine)
    }

    private var primaryTextColor: Color {
        style == .liquid ? .primary : .white
    }

    private var secondaryTextColor: Color {
        style == .liquid ? .secondary : Color.white.opacity(0.8)
    }

    private var borderColor: Color {
        style == .liquid ? Color.white.opacity(0.16) : Color.white.opacity(0.12)
    }

    private var shadowColor: Color {
        style == .liquid ? Color.black.opacity(0.22) : Color.black.opacity(0.28)
    }

    private var symbolColor: Color {
        style == .liquid ? .primary : .white
    }

    private var overlayGradient: some View {
        let colors: [Color]
        if style == .liquid {
            colors = [Color.white.opacity(0.32), Color.white.opacity(0.08)]
        } else {
            colors = [Color.white.opacity(0.15), Color.white.opacity(0.03)]
        }
        return RoundedRectangle(cornerRadius: 28, style: .continuous)
            .fill(
                LinearGradient(colors: colors,
                               startPoint: .topLeading,
                               endPoint: .bottomTrailing)
            )
            .allowsHitTesting(false)
    }
}

struct GlassBackground: NSViewRepresentable {
    enum Style {
        case frozen
        case liquid
    }

    let style: Style

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.state = .active
        view.blendingMode = .withinWindow
        configure(view)
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        configure(nsView)
    }

    private func configure(_ view: NSVisualEffectView) {
        switch style {
        case .frozen:
            // Legacy frozen glass matches the pre-macOS 26 HUD appearance
            view.material = .hudWindow
            view.isEmphasized = false
        case .liquid:
            // Liquid glass is the new macOS 26 treatment; fall back gracefully on older systems
            if #available(macOS 15, *) {
                view.material = .menu
            } else {
                view.material = .contentBackground
            }
            view.isEmphasized = true
        }
    }
}
