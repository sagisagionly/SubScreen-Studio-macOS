import AppKit
import CoreLocation
import Darwin
import EventKit
import Foundation
import IOBluetooth
import ServiceManagement
import SwiftUI

struct SystemMetricsSnapshot: Equatable {
    var cpuPercent: Double = 0
    var memoryPercent: Double = 0
    var gpuPercent: Double = 0
    var downloadBytesPerSecond: Double = 0
    var uploadBytesPerSecond: Double = 0
}

struct PSUTelemetrySnapshot: Equatable {
    var connected = false
    var model = "darkFlash VD1200P"
    var firmware = ""
    var rail3V3Volts = 0.0
    var rail3V3Amps = 0.0
    var rail5VVolts = 0.0
    var rail5VAmps = 0.0
    var rail12AVolts = 0.0
    var rail12AAmps = 0.0
    var rail12BVolts = 0.0
    var rail12BAmps = 0.0
    var temperatureCelsius = 0.0
    var fanRPM = 0.0
    var inputVolts = 0.0
    var inputPowerWatts = 0.0
    var updatedAt: Date?
}

private struct PSUTelemetryPayload: Decodable {
    var connected: Bool
    var model: String?
    var firmware: String?
    var rail3V3Volts: Double?
    var rail3V3Amps: Double?
    var rail5VVolts: Double?
    var rail5VAmps: Double?
    var rail12VAVolts: Double?
    var rail12VAAmps: Double?
    var rail12VBVolts: Double?
    var rail12VBAmps: Double?
    var temperatureCelsius: Double?
    var fanRPM: Double?
    var inputVolts: Double?
    var inputPowerWatts: Double?
    var error: String?

    enum CodingKeys: String, CodingKey {
        case connected, model, firmware, error
        case rail3V3Volts = "rail_3v3_volts"
        case rail3V3Amps = "rail_3v3_amps"
        case rail5VVolts = "rail_5v_volts"
        case rail5VAmps = "rail_5v_amps"
        case rail12VAVolts = "rail_12v_a_volts"
        case rail12VAAmps = "rail_12v_a_amps"
        case rail12VBVolts = "rail_12v_b_volts"
        case rail12VBAmps = "rail_12v_b_amps"
        case temperatureCelsius = "temperature_celsius"
        case fanRPM = "fan_rpm"
        case inputVolts = "input_volts"
        case inputPowerWatts = "input_power_watts"
    }
}

@MainActor
final class PSUMonitor: ObservableObject {
    static let shared = PSUMonitor()

    @Published private(set) var snapshot = PSUTelemetrySnapshot()
    @Published private(set) var status = "Looking for VD1200P…"

    private var process: Process?
    private var outputBuffer = Data()
    private var restartTimer: Timer?
    private var stopping = false

    private init() {
        start()
    }

    var isStale: Bool {
        guard let updatedAt = snapshot.updatedAt else { return true }
        return Date().timeIntervalSince(updatedAt) > 10
    }

    func start() {
        guard process?.isRunning != true, !stopping else { return }
        restartTimer?.invalidate()
        restartTimer = nil

        guard let executable = helperURL else {
            status = "Telemetry helper is unavailable"
            scheduleRestart()
            return
        }

        let pipe = Pipe()
        let task = Process()
        task.executableURL = executable
        task.arguments = ["psu-monitor", "--watch"]
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { @MainActor in self?.consume(data) }
        }
        task.terminationHandler = { [weak self] _ in
            pipe.fileHandleForReading.readabilityHandler = nil
            Task { @MainActor in
                guard let self else { return }
                self.process = nil
                if !self.stopping { self.scheduleRestart() }
            }
        }

        do {
            try task.run()
            process = task
            status = "Connecting to VD1200P…"
        } catch {
            status = "Could not start PSU telemetry"
            scheduleRestart()
        }
    }

    func stop() {
        stopping = true
        restartTimer?.invalidate()
        restartTimer = nil
        process?.terminate()
        process = nil
    }

    private var helperURL: URL? {
        let fileManager = FileManager.default
        var candidates: [URL] = []
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("ssp") {
            candidates.append(bundled)
        }
        let root = URL(fileURLWithPath: fileManager.currentDirectoryPath)
        candidates.append(root.appendingPathComponent("vendor/sub-screen-player/target/debug/ssp"))
        candidates.append(root.appendingPathComponent("vendor/sub-screen-player/target/release/ssp"))
        return candidates.first { fileManager.isExecutableFile(atPath: $0.path) }
    }

    private func consume(_ data: Data) {
        outputBuffer.append(data)
        while let newline = outputBuffer.firstIndex(of: 0x0a) {
            let line = outputBuffer[..<newline]
            outputBuffer.removeSubrange(...newline)
            guard !line.isEmpty,
                  let payload = try? JSONDecoder().decode(PSUTelemetryPayload.self, from: Data(line)) else { continue }
            apply(payload)
        }
    }

    private func apply(_ payload: PSUTelemetryPayload) {
        guard payload.connected else {
            if snapshot.connected {
                var next = snapshot
                next.connected = false
                snapshot = next
            }
            let nextStatus = payload.error ?? "VD1200P disconnected"
            if status != nextStatus { status = nextStatus }
            return
        }
        // Publish one coherent reading. Updating every field separately made
        // SwiftUI redraw the complete scene many times for a single USB report.
        var next = snapshot
        next.connected = true
        next.model = payload.model ?? next.model
        next.firmware = payload.firmware ?? next.firmware
        next.rail3V3Volts = payload.rail3V3Volts ?? next.rail3V3Volts
        next.rail3V3Amps = payload.rail3V3Amps ?? next.rail3V3Amps
        next.rail5VVolts = payload.rail5VVolts ?? next.rail5VVolts
        next.rail5VAmps = payload.rail5VAmps ?? next.rail5VAmps
        next.rail12AVolts = payload.rail12VAVolts ?? next.rail12AVolts
        next.rail12AAmps = payload.rail12VAAmps ?? next.rail12AAmps
        next.rail12BVolts = payload.rail12VBVolts ?? next.rail12BVolts
        next.rail12BAmps = payload.rail12VBAmps ?? next.rail12BAmps
        next.temperatureCelsius = payload.temperatureCelsius ?? next.temperatureCelsius
        next.fanRPM = payload.fanRPM ?? next.fanRPM
        next.inputVolts = payload.inputVolts ?? next.inputVolts
        next.inputPowerWatts = payload.inputPowerWatts ?? next.inputPowerWatts
        next.updatedAt = Date()
        snapshot = next
        if status != "Connected" { status = "Connected" }
    }

    private func scheduleRestart() {
        guard !stopping, restartTimer == nil else { return }
        restartTimer = Timer.scheduledTimer(withTimeInterval: 8, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.start() }
        }
    }
}

@MainActor
final class OutputPerformanceMonitor: ObservableObject {
    static let shared = OutputPerformanceMonitor()
    @Published var targetFPS: Double = 30
    @Published private(set) var measuredFPS: Double = 0
    private var deliveredFrames = 0
    private var timer: Timer?

    private init() {
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.measuredFPS = Double(self.deliveredFrames)
                self.deliveredFrames = 0
            }
        }
    }

    func recordDeliveredFrame() { deliveredFrames += 1 }
}

@MainActor
final class SystemMetricsMonitor: ObservableObject {
    static let shared = SystemMetricsMonitor()

    @Published private(set) var snapshot = SystemMetricsSnapshot()
    private var timer: Timer?
    private var previousCPU: (used: UInt64, total: UInt64)?
    private var previousNetwork: (received: UInt64, sent: UInt64, date: Date)?
    private var tick = 0

    private init() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        timer?.tolerance = 0.12
    }

    private func refresh() {
        var next = snapshot
        next.cpuPercent = readCPU()
        next.memoryPercent = readMemory()
        let network = readNetwork()
        next.downloadBytesPerSecond = network.received
        next.uploadBytesPerSecond = network.sent
        snapshot = next
        tick += 1
        if tick % 5 == 0 { refreshGPU() }
    }

    private func readCPU() -> Double {
        var info = host_cpu_load_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return snapshot.cpuPercent }
        let user = UInt64(info.cpu_ticks.0)
        let system = UInt64(info.cpu_ticks.1)
        let idle = UInt64(info.cpu_ticks.2)
        let nice = UInt64(info.cpu_ticks.3)
        let used = user + system + nice
        let total = used + idle
        defer { previousCPU = (used, total) }
        guard let previousCPU, total > previousCPU.total else { return snapshot.cpuPercent }
        return Double(used - previousCPU.used) / Double(total - previousCPU.total) * 100
    }

    private func readMemory() -> Double {
        var pageSize: vm_size_t = 0
        host_page_size(mach_host_self(), &pageSize)
        var info = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return snapshot.memoryPercent }
        let usedPages = UInt64(info.active_count) + UInt64(info.wire_count) + UInt64(info.compressor_page_count)
        let usedBytes = usedPages * UInt64(pageSize)
        return min(100, Double(usedBytes) / Double(ProcessInfo.processInfo.physicalMemory) * 100)
    }

    private func readNetwork() -> (received: Double, sent: Double) {
        var addresses: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addresses) == 0, let first = addresses else { return (0, 0) }
        defer { freeifaddrs(addresses) }

        var received: UInt64 = 0
        var sent: UInt64 = 0
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let item = cursor {
            let interface = item.pointee
            if interface.ifa_addr?.pointee.sa_family == UInt8(AF_LINK),
               interface.ifa_flags & UInt32(IFF_LOOPBACK) == 0,
               let data = interface.ifa_data?.assumingMemoryBound(to: if_data.self) {
                received += UInt64(data.pointee.ifi_ibytes)
                sent += UInt64(data.pointee.ifi_obytes)
            }
            cursor = interface.ifa_next
        }

        let now = Date()
        defer { previousNetwork = (received, sent, now) }
        guard let previousNetwork else { return (0, 0) }
        let interval = max(0.1, now.timeIntervalSince(previousNetwork.date))
        return (
            Double(received &- previousNetwork.received) / interval,
            Double(sent &- previousNetwork.sent) / interval
        )
    }

    private func refreshGPU() {
        Task.detached(priority: .utility) {
            let process = Process()
            let pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/ioreg")
            process.arguments = ["-r", "-c", "AGXFamilyAccelerator", "-l"]
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                let text = String(decoding: data, as: UTF8.self)
                let expression = try? NSRegularExpression(pattern: #"\"Device Utilization %\"=(\d+)"#)
                let range = NSRange(text.startIndex..., in: text)
                var value: Double?
                if let match = expression?.firstMatch(in: text, range: range),
                   let capture = Range(match.range(at: 1), in: text) {
                    value = Double(text[capture])
                }
                if let value {
                    await MainActor.run {
                        var next = self.snapshot
                        next.gpuPercent = min(max(value, 0), 100)
                        self.snapshot = next
                    }
                }
            } catch {
                // GPU utilization is unavailable on some Intel Macs; keep the last value.
            }
        }
    }
}

@MainActor
final class AirPodsMonitor: ObservableObject {
    static let shared = AirPodsMonitor()

    @Published private(set) var connectedName: String?
    @Published private(set) var connectionSequence = 0
    private var timer: Timer?
    private var refreshing = false

    private init() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 8, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        timer?.tolerance = 1
    }

    private func refresh() {
        guard !refreshing else { return }
        refreshing = true
        Task.detached(priority: .utility) {
            let devices = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] ?? []
            let connected = devices.first { device in
                let name = device.name ?? ""
                let isHeadphones = name.localizedCaseInsensitiveContains("AirPods") ||
                    name.localizedCaseInsensitiveContains("Beats")
                return isHeadphones && device.isConnected()
            }?.name
            await MainActor.run {
                self.refreshing = false
                if self.connectedName == nil, connected != nil { self.connectionSequence += 1 }
                self.connectedName = connected
            }
        }
    }
}

@MainActor
final class IPhoneConnectionMonitor: ObservableObject {
    static let shared = IPhoneConnectionMonitor()

    @Published private(set) var connectedName: String?
    @Published private(set) var connectionSequence = 0
    private var timer: Timer?
    private var refreshing = false

    private init() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        timer?.tolerance = 1
    }

    private func refresh() {
        guard !refreshing else { return }
        refreshing = true
        Task.detached(priority: .utility) {
            let process = Process()
            let pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/ioreg")
            process.arguments = ["-p", "IOUSB", "-l", "-w", "0"]
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            var name: String?
            do {
                try process.run()
                let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                process.waitUntilExit()
                if text.localizedCaseInsensitiveContains("iPhone") { name = "iPhone" }
                else if text.localizedCaseInsensitiveContains("iPad") { name = "iPad" }
            } catch { }
            let detectedName = name
            await MainActor.run {
                self.refreshing = false
                if self.connectedName == nil, detectedName != nil { self.connectionSequence += 1 }
                self.connectedName = detectedName
            }
        }
    }
}

@MainActor
final class LaunchAtLoginController: ObservableObject {
    static let shared = LaunchAtLoginController()

    @Published private(set) var enabled = SMAppService.mainApp.status == .enabled
    @Published private(set) var statusText = ""

    private init() { refresh() }

    func setEnabled(_ shouldEnable: Bool) {
        do {
            if shouldEnable { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            refresh()
        } catch {
            refresh()
            statusText = error.localizedDescription
        }
    }

    func refresh() {
        enabled = SMAppService.mainApp.status == .enabled
        if statusText.isEmpty {
            statusText = enabled ? "Opens automatically after you sign in." : "The app stays closed when you sign in."
        }
    }
}

@MainActor
final class NowPlayingMonitor: ObservableObject {
    static let shared = NowPlayingMonitor()

    private(set) var title = "Nothing playing"
    private(set) var artist = "Apple Music or YouTube Music"
    private(set) var source = ""
    private(set) var progress: Double = 0
    private(set) var position: Double = 0
    private(set) var duration: Double = 1
    @Published var artwork: NSImage?
    @Published var lyricLines: [LyricLine] = []
    @Published var plainLyrics: String?
    @Published var lyricsStatus = "Play a song to find lyrics"
    private var metadataTimer: Timer?
    private var positionTimer: Timer?
    private var refreshing = false
    private var isPlaying = false
    private var editorInteractionDepth = 0
    var artworkTask: Task<Void, Never>?
    var lyricsTask: Task<Void, Never>?
    private var mediaIdentity = ""

    private init() {
        refresh()
        metadataTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        metadataTimer?.tolerance = 0.25
        let positionInterval = 1.0 / 10.0
        positionTimer = Timer.scheduledTimer(withTimeInterval: positionInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.editorInteractionDepth == 0, self.isPlaying, self.duration > 1 else { return }
                self.objectWillChange.send()
                self.position = min(self.duration, self.position + positionInterval)
                self.progress = min(max(self.position / self.duration, 0), 1)
            }
        }
        positionTimer?.tolerance = 0.015
    }

    func reloadMediaMetadata() {
        mediaIdentity = ""
        refresh()
    }

    func setEditorInteraction(active: Bool) {
        editorInteractionDepth = max(0, editorInteractionDepth + (active ? 1 : -1))
    }

    private func refresh() {
        guard !refreshing else { return }
        refreshing = true
        Task {
            let pear = await Self.readPearNowPlaying()
            let result: Snapshot?
            if let pear { result = pear }
            else { result = await Task.detached(priority: .utility) { Self.readNowPlaying() }.value }
            await MainActor.run {
                self.refreshing = false
                guard let result else { return }
                self.objectWillChange.send()
                self.title = result.title
                self.artist = result.artist
                self.source = result.source
                self.progress = result.progress
                self.position = result.position
                self.duration = result.duration
                self.isPlaying = result.isPlaying
                let identity = "\(result.title)|\(result.artist)|\(Int(result.duration.rounded()))"
                if identity != self.mediaIdentity {
                    self.mediaIdentity = identity
                    self.refreshArtworkAndLyrics(
                        for: result.title,
                        artist: result.artist,
                        album: result.album,
                        duration: result.duration,
                        source: result.source,
                        videoID: result.videoID,
                        exactArtworkData: result.artworkData,
                        exactArtworkURL: result.artworkURL
                    )
                } else if self.artwork == nil, let data = result.artworkData, let image = NSImage(data: data) {
                    self.artwork = image
                }
            }
        }
    }

    struct Snapshot: Sendable {
        let title: String
        let artist: String
        let album: String?
        let source: String
        let progress: Double
        let position: Double
        let duration: Double
        let isPlaying: Bool
        let artworkData: Data?
        let artworkURL: URL?
        let videoID: String?
    }

    nonisolated private static func readPearNowPlaying() async -> Snapshot? {
        struct PearSong: Decodable {
            let title: String
            let artist: String
            let album: String?
            let imageSrc: String?
            let videoId: String?
            let isPaused: Bool?
            let songDuration: Double
            let elapsedSeconds: Double?
        }
        guard let url = URL(string: "http://127.0.0.1:26538/api/v1/song") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 0.7
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let song = try? JSONDecoder().decode(PearSong.self, from: data),
              !song.title.isEmpty else { return nil }
        let duration = max(1, song.songDuration)
        let position = min(max(0, song.elapsedSeconds ?? 0), duration)
        return Snapshot(title: song.title, artist: song.artist, album: song.album, source: "Pear Desktop", progress: position / duration, position: position, duration: duration, isPlaying: !(song.isPaused ?? false), artworkData: nil, artworkURL: song.imageSrc.flatMap(URL.init(string:)), videoID: song.videoId)
    }

    nonisolated private static func readNowPlaying() -> Snapshot? {
        if let systemMedia = readSystemNowPlaying() { return systemMedia }
        let musicScript = """
        tell application "Music" to if player state is playing then return (name of current track) & "|||" & (artist of current track) & "|||" & (album of current track) & "|||" & (player position as text) & "|||" & (duration of current track as text)
        """
        if let output = runAppleScript(musicScript) {
            let parts = output.components(separatedBy: "|||")
            if parts.count == 5 {
                let position = Double(parts[3]) ?? 0
                let duration = max(1, Double(parts[4]) ?? 1)
                return Snapshot(title: parts[0], artist: parts[1], album: parts[2], source: "Apple Music", progress: min(max(position / duration, 0), 1), position: position, duration: duration, isPlaying: true, artworkData: nil, artworkURL: nil, videoID: nil)
            }
        }

        let browserScript = """
set foundTitle to ""
set foundURL to ""
tell application "System Events"
    set browserNames to {"Safari", "Google Chrome", "Microsoft Edge"}
    repeat with browserName in browserNames
        if exists process browserName then
            try
                if browserName is "Safari" then
                    tell application "Safari" to repeat with w in windows
                        repeat with t in tabs of w
                            if URL of t contains "music.youtube.com" then
                                set foundTitle to name of t
                                set foundURL to URL of t
                            end if
                        end repeat
                    end repeat
                else if browserName is "Google Chrome" then
                    tell application "Google Chrome" to repeat with w in windows
                        repeat with t in tabs of w
                            if URL of t contains "music.youtube.com" then
                                set foundTitle to title of t
                                set foundURL to URL of t
                            end if
                        end repeat
                    end repeat
                else if browserName is "Microsoft Edge" then
                    tell application "Microsoft Edge" to repeat with w in windows
                        repeat with t in tabs of w
                            if URL of t contains "music.youtube.com" then
                                set foundTitle to title of t
                                set foundURL to URL of t
                            end if
                        end repeat
                    end repeat
                end if
            end try
        end if
    end repeat
end tell
return foundTitle & "|||URL|||" & foundURL
"""
        if let output = runAppleScript(browserScript), !output.isEmpty {
            let browserParts = output.components(separatedBy: "|||URL|||")
            let clean = browserParts[0].replacingOccurrences(of: " - YouTube Music", with: "")
            let videoID = browserParts.count > 1 ? youtubeVideoID(from: browserParts[1]) : nil
            for separator in [" • ", " - "] {
                let parts = clean.components(separatedBy: separator)
                if parts.count >= 2 {
                    return Snapshot(title: parts[0], artist: parts[1], album: nil, source: "YouTube Music", progress: 0, position: 0, duration: 1, isPlaying: true, artworkData: nil, artworkURL: nil, videoID: videoID)
                }
            }
            return Snapshot(title: clean, artist: "YouTube Music", album: nil, source: "YouTube Music", progress: 0, position: 0, duration: 1, isPlaying: true, artworkData: nil, artworkURL: nil, videoID: videoID)
        }
        return nil
    }

    nonisolated private static func readSystemNowPlaying() -> Snapshot? {
        typealias InfoCallback = @convention(block) (CFDictionary?) -> Void
        typealias GetInfo = @convention(c) (DispatchQueue, InfoCallback) -> Void
        guard let framework = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW),
              let symbol = dlsym(framework, "MRMediaRemoteGetNowPlayingInfo") else { return nil }
        defer { dlclose(framework) }
        let getInfo = unsafeBitCast(symbol, to: GetInfo.self)
        let semaphore = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var captured: [String: Any]?
        let callback: InfoCallback = { dictionary in
            lock.lock(); captured = dictionary as? [String: Any]; lock.unlock()
            semaphore.signal()
        }
        getInfo(DispatchQueue.global(qos: .utility), callback)
        guard semaphore.wait(timeout: .now() + 0.8) == .success else { return nil }
        lock.lock(); let info = captured; lock.unlock()
        guard let info,
              let title = info["kMRMediaRemoteNowPlayingInfoTitle"] as? String,
              !title.isEmpty else { return nil }
        let artist = (info["kMRMediaRemoteNowPlayingInfoArtist"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Unknown Artist"
        let album = info["kMRMediaRemoteNowPlayingInfoAlbum"] as? String
        let duration = max(1, (info["kMRMediaRemoteNowPlayingInfoDuration"] as? NSNumber)?.doubleValue ?? 1)
        let elapsed = min(max(0, (info["kMRMediaRemoteNowPlayingInfoElapsedTime"] as? NSNumber)?.doubleValue ?? 0), duration)
        let rate = (info["kMRMediaRemoteNowPlayingInfoPlaybackRate"] as? NSNumber)?.doubleValue ?? 0
        let bundleID = (info["kMRMediaRemoteNowPlayingInfoClientBundleIdentifier"] as? String) ?? ""
        let source: String
        if bundleID.localizedCaseInsensitiveContains("pear") { source = "Pear Desktop" }
        else if bundleID.localizedCaseInsensitiveContains("chrome") || bundleID.localizedCaseInsensitiveContains("safari") || bundleID.localizedCaseInsensitiveContains("edge") { source = "YouTube Music" }
        else if bundleID.localizedCaseInsensitiveContains("music") { source = "Apple Music" }
        else if bundleID.localizedCaseInsensitiveContains("spotify") { source = "Spotify" }
        else { source = "Now Playing" }
        let artwork = info["kMRMediaRemoteNowPlayingInfoArtworkData"] as? Data
        let contentID = info["kMRMediaRemoteNowPlayingInfoContentItemIdentifier"] as? String
        return Snapshot(title: title, artist: artist, album: album, source: source, progress: elapsed / duration, position: elapsed, duration: duration, isPlaying: rate > 0, artworkData: artwork, artworkURL: nil, videoID: youtubeVideoID(from: contentID))
    }

    nonisolated private static func youtubeVideoID(from value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        if let components = URLComponents(string: value),
           let id = components.queryItems?.first(where: { $0.name == "v" })?.value,
           !id.isEmpty { return id }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        if value.count == 11, value.unicodeScalars.allSatisfy({ allowed.contains($0) }) { return value }
        return nil
    }

    nonisolated private static func runAppleScript(_ script: String) -> String? {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return nil
        }
    }
}

func formattedRate(_ bytes: Double) -> String {
    let formatter = ByteCountFormatter()
    formatter.countStyle = .file
    formatter.allowedUnits = bytes >= 1_000_000 ? [.useMB] : [.useKB]
    return formatter.string(fromByteCount: Int64(max(0, bytes))) + "/s"
}

struct EnvironmentSnapshot: Equatable {
    var place = "Current location"
    var temperature: Double?
    var feelsLike: Double?
    var humidity: Double?
    var wind: Double?
}

final class CurrentEnvironmentMonitor: NSObject, ObservableObject, CLLocationManagerDelegate {
    static let shared = CurrentEnvironmentMonitor()
    @Published private(set) var snapshot = EnvironmentSnapshot()
    @Published private(set) var status = "Allow location to show local conditions"
    private let manager = CLLocationManager()

    override private init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
    }

    func requestLocation() {
        status = "Finding your location…"
        manager.requestWhenInUseAuthorization()
        manager.requestLocation()
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse: manager.requestLocation()
        case .denied, .restricted: DispatchQueue.main.async { self.status = "Location access is off in System Settings" }
        default: break
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        CLGeocoder().reverseGeocodeLocation(location) { places, _ in
            let place = places?.first
            let name = [place?.locality, place?.administrativeArea, place?.country]
                .compactMap { $0 }.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }.joined(separator: ", ")
            DispatchQueue.main.async {
                if !name.isEmpty { self.snapshot.place = name }
            }
        }
        Task { await fetchWeather(latitude: location.coordinate.latitude, longitude: location.coordinate.longitude) }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        DispatchQueue.main.async { self.status = error.localizedDescription }
    }

    private func fetchWeather(latitude: Double, longitude: Double) async {
        struct Response: Decodable {
            struct Current: Decodable {
                let temperature2m: Double
                let apparentTemperature: Double
                let relativeHumidity2m: Double
                let windSpeed10m: Double
                enum CodingKeys: String, CodingKey {
                    case temperature2m = "temperature_2m", apparentTemperature = "apparent_temperature"
                    case relativeHumidity2m = "relative_humidity_2m", windSpeed10m = "wind_speed_10m"
                }
            }
            let current: Current
        }
        var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        components.queryItems = [
            .init(name: "latitude", value: String(latitude)), .init(name: "longitude", value: String(longitude)),
            .init(name: "current", value: "temperature_2m,apparent_temperature,relative_humidity_2m,wind_speed_10m"),
            .init(name: "timezone", value: "auto")
        ]
        guard let url = components.url,
              let (data, _) = try? await URLSession.shared.data(from: url),
              let response = try? JSONDecoder().decode(Response.self, from: data) else {
            await MainActor.run { status = "Could not load local conditions" }
            return
        }
        await MainActor.run {
            snapshot.temperature = response.current.temperature2m
            snapshot.feelsLike = response.current.apparentTemperature
            snapshot.humidity = response.current.relativeHumidity2m
            snapshot.wind = response.current.windSpeed10m
            status = snapshot.place
        }
    }
}

@MainActor
final class ScreenTimeMonitor: ObservableObject {
    static let shared = ScreenTimeMonitor()
    @Published private(set) var totals: [String: Double] = [:]
    private var currentApp = NSWorkspace.shared.frontmostApplication?.localizedName ?? "Other"
    private var lastTick = Date()
    private var timer: Timer?
    private var dayKey = ""
    private var lastPersisted = Date.distantPast

    private init() {
        dayKey = ScreenTimeMonitor.todayKey
        totals = UserDefaults.standard.dictionary(forKey: storageKey) as? [String: Double] ?? [:]
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        timer?.tolerance = 0.15
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            Task { @MainActor in self?.switchTo(app.localizedName ?? "Other") }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                UserDefaults.standard.set(self.totals, forKey: self.storageKey)
            }
        }
    }

    var totalSeconds: Double { totals.values.reduce(0, +) }
    var topApps: [(String, Double)] { Array(totals.sorted { $0.value > $1.value }.prefix(4)) }

    private var storageKey: String { "screenTime.\(dayKey)" }
    private static var todayKey: String { String(Int(Calendar.current.startOfDay(for: Date()).timeIntervalSince1970)) }

    private func switchTo(_ app: String) { tick(); currentApp = app }
    private func tick() {
        let now = Date()
        if dayKey != Self.todayKey {
            dayKey = Self.todayKey; totals = [:]
        }
        let elapsed = min(5, max(0, now.timeIntervalSince(lastTick)))
        lastTick = now
        totals[currentApp, default: 0] += elapsed
        if now.timeIntervalSince(lastPersisted) >= 30 {
            UserDefaults.standard.set(totals, forKey: storageKey)
            lastPersisted = now
        }
    }
}

@MainActor
final class AgendaMonitor: ObservableObject {
    static let shared = AgendaMonitor()

    @Published private(set) var nextEventTitle = "Connect Calendar"
    @Published private(set) var nextEventDate: Date?
    @Published private(set) var reminders: [String] = []
    @Published private(set) var calendarAccessDenied = false
    @Published private(set) var reminderAccessDenied = false

    private let store = EKEventStore()
    private var calendarRequested = false
    private var remindersRequested = false

    private init() {}

    func connectCalendar() {
        guard !calendarRequested else { refreshCalendar(); return }
        calendarRequested = true
        Task {
            do {
                let granted = try await store.requestFullAccessToEvents()
                calendarAccessDenied = !granted
                if granted { refreshCalendar() }
            } catch {
                calendarAccessDenied = true
            }
        }
    }

    func connectReminders() {
        guard !remindersRequested else { refreshReminders(); return }
        remindersRequested = true
        Task {
            do {
                let granted = try await store.requestFullAccessToReminders()
                reminderAccessDenied = !granted
                if granted { refreshReminders() }
            } catch {
                reminderAccessDenied = true
            }
        }
    }

    private func refreshCalendar() {
        let start = Date()
        let end = Calendar.current.date(byAdding: .day, value: 14, to: start) ?? start.addingTimeInterval(1_209_600)
        let events = store.events(matching: store.predicateForEvents(withStart: start, end: end, calendars: nil))
            .filter { $0.endDate > start }
            .sorted { $0.startDate < $1.startDate }
        nextEventTitle = events.first?.title ?? "No upcoming events"
        nextEventDate = events.first?.startDate
    }

    private func refreshReminders() {
        let predicate = store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: nil)
        store.fetchReminders(matching: predicate) { [weak self] items in
            let titles = (items ?? []).compactMap(\.title).prefix(4)
            Task { @MainActor in self?.reminders = Array(titles) }
        }
    }
}
