import AppKit
import CoreGraphics
import Foundation
import ScreenCaptureKit

@MainActor
final class HardwareTemperatureMonitor: ObservableObject {
    static let shared = HardwareTemperatureMonitor()
    @Published private(set) var cpuTemperature: Double?
    @Published private(set) var gpuTemperature: Double?
    @Published private(set) var status = "Checking sensor support…"
    @Published private(set) var installing = false
    private var timer: Timer?
    private var refreshing = false

    var isAvailable: Bool { Self.macmonPath != nil }
    private static var macmonPath: String? {
        ["/opt/homebrew/bin/macmon", "/usr/local/bin/macmon"].first(where: FileManager.default.isExecutableFile(atPath:))
    }

    private init() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        timer?.tolerance = 0.6
    }

    func refresh() {
        guard !refreshing else { return }
        guard let executable = Self.macmonPath else {
            status = "Install the sensor helper once to read Apple Silicon temperatures"
            return
        }
        refreshing = true
        Task {
            let values = await Task.detached(priority: .utility) {
                let result = await YouTubeMediaResolver.run(executable: executable, arguments: ["pipe", "-s", "1", "-i", "200"])
                return Self.parse(result.1)
            }.value
            if let values {
                cpuTemperature = values.cpu
                gpuTemperature = values.gpu
                status = values.cpu == nil && values.gpu == nil ? "Temperature sensors are unavailable on this Mac" : "Live • updates every 3 seconds"
            } else {
                status = "Could not read temperature sensors"
            }
            refreshing = false
        }
    }

    func installSupport() {
        guard !installing,
              let brew = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"].first(where: FileManager.default.isExecutableFile(atPath:)) else {
            status = "Homebrew is required to install the macmon sensor helper"
            return
        }
        installing = true
        status = "Installing sensor helper…"
        Task {
            let result = await YouTubeMediaResolver.run(executable: brew, arguments: ["install", "macmon"])
            installing = false
            status = result.0 == 0 ? "Sensor helper installed" : "Installation failed: \(result.1)"
            refresh()
        }
    }

    nonisolated private static func parse(_ output: String) -> (cpu: Double?, gpu: Double?)? {
        guard let start = output.firstIndex(of: "{"), let end = output.lastIndex(of: "}") else { return nil }
        let json = String(output[start...end])
        guard let data = json.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let temperatures = root["temp"] as? [String: Any] else { return nil }
        return (
            (temperatures["cpu_temp_avg"] as? NSNumber)?.doubleValue,
            (temperatures["gpu_temp_avg"] as? NSNumber)?.doubleValue
        )
    }
}

struct CapturableWindow: Identifiable, Hashable {
    let id: String
    let title: String
}

@MainActor
final class WindowCaptureMonitor: ObservableObject {
    static let shared = WindowCaptureMonitor()
    @Published private(set) var windows: [CapturableWindow] = []
    @Published private(set) var images: [String: NSImage] = [:]
    @Published private(set) var status = "Choose a window to begin"
    private var systemWindows: [String: SCWindow] = [:]
    private var activeIDs = Set<String>()
    private var capturesInFlight = Set<String>()
    private var timer: Timer?

    private init() {}

    func refreshWindows() {
        status = "Loading available windows…"
        Task {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
                let candidates = content.windows.filter {
                    $0.frame.width >= 100 && $0.frame.height >= 80 &&
                    $0.owningApplication?.bundleIdentifier != Bundle.main.bundleIdentifier &&
                    !(($0.title ?? "").isEmpty)
                }
                systemWindows = Dictionary(uniqueKeysWithValues: candidates.map { (String($0.windowID), $0) })
                windows = candidates.map {
                    let app = $0.owningApplication?.applicationName ?? "App"
                    return CapturableWindow(id: String($0.windowID), title: "\(app) — \($0.title ?? "Window")")
                }.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
                status = windows.isEmpty ? "No windows available. Check Screen Recording permission." : "Choose one of \(windows.count) windows"
                captureActiveWindows()
            } catch {
                status = "Allow Screen Recording in System Settings, then reopen the app"
            }
        }
    }

    func start(windowID: String) {
        guard !windowID.isEmpty else { return }
        activeIDs.insert(windowID)
        startTimerIfNeeded()
        if systemWindows[windowID] == nil { refreshWindows() }
        else { capture(windowID: windowID) }
    }

    func stop(windowID: String) {
        activeIDs.remove(windowID)
        guard activeIDs.isEmpty else { return }
        timer?.invalidate()
        timer = nil
        images.removeValue(forKey: windowID)
    }

    private func startTimerIfNeeded() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.captureActiveWindows() }
        }
        timer?.tolerance = 0.06
    }

    private func captureActiveWindows() {
        for id in activeIDs { capture(windowID: id) }
    }

    private func capture(windowID: String) {
        guard !capturesInFlight.contains(windowID), let window = systemWindows[windowID] else { return }
        capturesInFlight.insert(windowID)
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let configuration = SCStreamConfiguration()
        let ratio = max(0.1, window.frame.width / max(window.frame.height, 1))
        configuration.width = min(1920, max(320, Int(window.frame.width * 2)))
        configuration.height = min(1080, max(180, Int(Double(configuration.width) / ratio)))
        configuration.showsCursor = false
        SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration) { [weak self] image, error in
            Task { @MainActor in
                guard let self else { return }
                self.capturesInFlight.remove(windowID)
                if let image {
                    self.images[windowID] = NSImage(cgImage: image, size: .zero)
                    self.status = "Live window capture"
                } else if error != nil {
                    self.status = "Window capture paused or permission was removed"
                }
            }
        }
    }
}
