import AppKit
import AVFoundation
import AVKit
import ImageIO
import SwiftUI
import WebKit

struct WidgetContent: View, Equatable {
    let layer: StudioLayer
    let scale: Double

    static func == (lhs: WidgetContent, rhs: WidgetContent) -> Bool {
        lhs.layer == rhs.layer && lhs.scale == rhs.scale
    }

    var body: some View {
        Group {
            switch layer.kind {
            case .clock: ClockWidget(layer: layer, scale: scale)
            case .weather: WeatherWidget(layer: layer, scale: scale)
            case .codex: CodexWidget(layer: layer, scale: scale)
            case .image: ImageWidget(layer: layer)
            case .video: VideoWidget(layer: layer)
            case .text: TextWidget(layer: layer, scale: scale)
            case .shape:
                Color(studioHex: layer.backgroundHex)
            case .nowPlaying: NowPlayingWidget(layer: layer, scale: scale)
            case .lyrics: LyricsWidget(layer: layer, scale: scale)
            case .systemMonitor: SystemMonitorWidget(layer: layer, scale: scale)
            case .networkSpeed: NetworkSpeedWidget(layer: layer, scale: scale)
            case .temperature: TemperatureWidget(layer: layer, scale: scale)
            case .fps: FPSWidget(layer: layer, scale: scale)
            case .windowCapture: WindowCaptureWidget(layer: layer)
            case .powerSupply: PowerSupplyWidget(layer: layer, scale: scale)
            case .airPods: AirPodsWidget(layer: layer, scale: scale)
            case .youtube: YouTubeWidget(layer: layer)
            case .rss: NewsFeedWidget(layer: layer, scale: scale)
            case .focusTimer: FocusTimerWidget(layer: layer, scale: scale)
            case .worldClock: WorldClockWidget(layer: layer, scale: scale)
            case .audioVisualizer: AudioVisualizerWidget(layer: layer, scale: scale)
            case .photoAlbum: ImageWidget(layer: layer)
            case .calendar: CalendarWidget(layer: layer, scale: scale)
            case .reminders: RemindersWidget(layer: layer, scale: scale)
            case .notification, .finance, .sports,
                 .transit, .github, .smartHome, .chatStatus, .creatorCounter,
                 .webSnapshot, .packageTracker, .messageBoard:
                GenericInfoWidget(layer: layer, scale: scale)
            case .environment: EnvironmentWidget(layer: layer, scale: scale)
            case .screenTime: ScreenTimeWidget(layer: layer, scale: scale)
            }
        }
        // The visual surface must occupy the complete transform rectangle.
        // Applying the background to intrinsic content left transparent bands
        // inside the selection box, making corner radius look like an outer
        // frame control instead of the widget's real mask.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(studioHex: layer.backgroundHex))
    }
}

struct ClockWidget: View {
    let layer: StudioLayer
    let scale: Double

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            GeometryReader { proxy in
                let compact = proxy.size.width < 380 || proxy.size.height < 205
                let wide = proxy.size.width / max(proxy.size.height, 1) > 2.35
                let padding = min(28.0, max(14.0, min(proxy.size.width, proxy.size.height) * 0.085))
                let timeSize = min(
                    layer.fontSize * (wide ? 1.65 : compact ? 1.34 : 1.75),
                    proxy.size.height * (wide ? 0.48 : compact ? 0.44 : 0.38)
                )

                Group {
                    if wide {
                        HStack(spacing: padding) {
                            timeText(context.date, size: timeSize)
                            Spacer(minLength: 8)
                            VStack(alignment: .trailing, spacing: 5) {
                                Text(formatted(context.date, pattern: "EEEE"))
                                    .font(.system(size: max(15, timeSize * 0.25), weight: .semibold))
                                Text(formatted(context.date, pattern: "MMMM d"))
                                    .font(.system(size: max(12, timeSize * 0.19), weight: .medium))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    } else {
                        VStack(alignment: compact ? .center : .leading, spacing: compact ? 5 : 9) {
                            timeText(context.date, size: timeSize)
                            Text(formatted(context.date, pattern: compact ? "EEE, MMM d" : "EEEE, MMMM d"))
                                .font(.system(size: max(12, timeSize * (compact ? 0.23 : 0.25)), weight: .medium))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.72)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: compact ? .center : .leading)
                    }
                }
                .padding(padding)
            }
            .foregroundStyle(Color(studioHex: layer.foregroundHex))
        }
    }

    private func timeText(_ date: Date, size: Double) -> some View {
        Text(formatted(date, pattern: "HH:mm"))
            .font(.system(size: max(28, size), weight: .semibold, design: .rounded))
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.7)
    }

    private func formatted(_ date: Date, pattern: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.timeZone = layer.configValue("timeZone").isEmpty
            ? .current
            : TimeZone(identifier: layer.configValue("timeZone")) ?? .current
        formatter.dateFormat = pattern
        return formatter.string(from: date)
    }
}

struct WeatherResponse: Decodable {
    let current: Current
    struct Current: Decodable {
        let temperature2m: Double
        let weatherCode: Int
        let isDay: Int
        enum CodingKeys: String, CodingKey {
            case temperature2m = "temperature_2m"
            case weatherCode = "weather_code"
            case isDay = "is_day"
        }
    }
}

struct WeatherWidget: View {
    let layer: StudioLayer
    let scale: Double

    var body: some View {
        GeometryReader { proxy in
            let compact = proxy.size.width < 380 || proxy.size.height < 205
            let wide = proxy.size.width / max(proxy.size.height, 1) > 2.35
            let padding = min(28.0, max(14.0, min(proxy.size.width, proxy.size.height) * 0.085))
            let iconSize = min(proxy.size.height * (compact ? 0.32 : 0.38), proxy.size.width * 0.22)
            let temperatureSize = min(layer.fontSize * (wide ? 1.45 : compact ? 1.05 : 1.35), proxy.size.height * 0.38)

            HStack(spacing: max(12, padding * 0.75)) {
                Image(systemName: weatherSymbol)
                    .symbolRenderingMode(.multicolor)
                    .font(.system(size: max(30, iconSize)))
                    .frame(width: max(44, iconSize * 1.2))
                VStack(alignment: .leading, spacing: compact ? 2 : 6) {
                    Text(temperatureText)
                        .font(.system(size: max(28, temperatureSize), weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .lineLimit(1)
                    Text(layer.locationName)
                        .font(.system(size: max(12, temperatureSize * 0.27), weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(wide ? 1 : 2)
                        .minimumScaleFactor(0.72)
                }
                Spacer(minLength: 0)
            }
            .foregroundStyle(Color(studioHex: layer.foregroundHex))
            .padding(padding)
        }
    }

    private var temperatureText: String {
        guard let celsius = layer.weatherTemperature else { return "—°" }
        if layer.configValue("temperatureUnit", fallback: "celsius") == "fahrenheit" {
            return "\(Int((celsius * 9 / 5 + 32).rounded()))°F"
        }
        return "\(Int(celsius.rounded()))°C"
    }

    private var weatherSymbol: String {
        switch layer.weatherCode {
        case 0: layer.weatherIsDay ? "sun.max.fill" : "moon.stars.fill"
        case 1...3: "cloud.sun.fill"
        case 45...48: "cloud.fog.fill"
        case 51...67, 80...82: "cloud.rain.fill"
        case 71...77, 85...86: "cloud.snow.fill"
        case 95...99: "cloud.bolt.rain.fill"
        default: "cloud.fill"
        }
    }
}

struct SceneOutputView: View {
    let scene: StudioScene
    let canvasSize: CGSize

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color(studioHex: scene.backgroundHex)
            ForEach(scene.layers) { layer in
                if !layer.isHidden {
                    TransformedWidgetContent(layer: layer, frame: layer.frame.rect, previewScale: 1, forOutput: true)
                        .clipShape(RoundedRectangle(cornerRadius: layer.cornerRadius))
                        .opacity(layer.opacity)
                        .position(x: layer.frame.x + layer.frame.width / 2, y: layer.frame.y + layer.frame.height / 2)
                }
            }
        }
        .frame(width: canvasSize.width, height: canvasSize.height)
    }
}

/// Renders each widget once in its saved design coordinate space, then applies
/// a GPU transform. Preview zoom and freeform resizing therefore use exactly
/// the same pixels as the 1920×462 output and do not repeatedly rebuild text,
/// images, or live media while the pointer moves.
struct TransformedWidgetContent: View {
    let layer: StudioLayer
    let frame: CGRect
    let previewScale: Double
    var forOutput = false

    private var designWidth: Double { max(1, layer.numberValue("designWidth", fallback: layer.frame.width)) }
    private var designHeight: Double { max(1, layer.numberValue("designHeight", fallback: layer.frame.height)) }

    var body: some View {
        Group {
            if forOutput { OutputWidgetContent(layer: layer, scale: 1) }
            else { WidgetContent(layer: layer, scale: 1).equatable() }
        }
        .frame(width: designWidth, height: designHeight)
        .scaleEffect(
            x: frame.width / designWidth * previewScale,
            y: frame.height / designHeight * previewScale
        )
        .frame(width: frame.width * previewScale, height: frame.height * previewScale)
        .clipped()
    }
}

/// The live-output renderer must stay fully renderable by SwiftUI's ImageRenderer.
/// Embedding a VideoPlayer in that off-screen tree repeatedly creates and tears down
/// AVKit views, which can abort the process. The output path therefore samples
/// AVPlayer pixel buffers and composites the current frame as a normal image.
struct OutputWidgetContent: View {
    let layer: StudioLayer
    let scale: Double

    var body: some View {
        if layer.kind == .video || layer.kind == .youtube {
            if let frame = OutputVideoFrameCenter.shared.image(for: layer.id) {
                Image(nsImage: frame)
                    .resizable()
                    .scaledToFill()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
            } else {
                VideoOutputCard(layer: layer, scale: scale)
            }
        } else {
            WidgetContent(layer: layer, scale: scale)
        }
    }
}

struct CodexWidget: View {
    let layer: StudioLayer
    let scale: Double
    @ObservedObject private var codex = CodexBridgeMonitor.shared

    private var used: Double { codex.usedPercent ?? layer.codexUsedPercent }
    private var resetLabel: String {
        if let date = codex.resetDate { return "Resets " + date.formatted(.relative(presentation: .named)) }
        return layer.codexResetLabel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18 * scale) {
            HStack {
                Label("CODEX", systemImage: "sparkles")
                    .font(.system(size: max(9, 22 * scale), weight: .semibold))
                    .foregroundStyle(Color(studioHex: "#9FA8FF"))
                Spacer()
                Text("\(Int(used))% used")
                    .font(.system(size: max(8, 18 * scale), weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.09))
                    Capsule()
                        .fill(LinearGradient(colors: [.blue, .purple], startPoint: .leading, endPoint: .trailing))
                        .frame(width: proxy.size.width * min(max(used / 100, 0), 1))
                }
            }
            .frame(height: max(6, 14 * scale))
            HStack(alignment: .lastTextBaseline) {
                Text("\(Int(max(0, 100 - used)))%")
                    .font(.system(size: max(18, layer.fontSize * scale), weight: .semibold, design: .rounded))
                Text("remaining")
                    .font(.system(size: max(8, 18 * scale), weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            HStack {
                Text(resetLabel)
                Spacer()
                if let approval = codex.pendingApproval {
                    Label(approval, systemImage: "exclamationmark.shield.fill").foregroundStyle(.orange)
                } else {
                    Label(codex.connected ? "Live" : "Offline", systemImage: codex.connected ? "bolt.fill" : "bolt.slash")
                }
            }
            .font(.system(size: max(8, 17 * scale), weight: .medium))
            .foregroundStyle(.secondary)
        }
        .foregroundStyle(Color(studioHex: layer.foregroundHex))
        .padding(32 * scale)
    }
}

struct ImageWidget: View {
    let layer: StudioLayer
    var body: some View {
        if let path = layer.assetPath, let image = StudioImageCache.shared.image(at: path) {
            Image(nsImage: image).resizable().scaledToFill()
        } else {
            ContentUnavailableView("Image unavailable", systemImage: "photo")
        }
    }
}

@MainActor
private final class StudioImageCache {
    static let shared = StudioImageCache()

    private let cache = NSCache<NSString, NSImage>()
    private var modificationDates: [String: Date] = [:]

    private init() {
        cache.countLimit = 24
    }

    func image(at path: String) -> NSImage? {
        let modificationDate = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate]) as? Date
        if modificationDates[path] == modificationDate,
           let cached = cache.object(forKey: path as NSString) {
            return cached
        }
        let url = URL(fileURLWithPath: path) as CFURL
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 2200,
            kCGImageSourceShouldCacheImmediately: true
        ]
        let decoded = CGImageSourceCreateWithURL(url, nil)
            .flatMap { CGImageSourceCreateThumbnailAtIndex($0, 0, options as CFDictionary) }
            .map { NSImage(cgImage: $0, size: .zero) }
        guard let image = decoded ?? NSImage(contentsOfFile: path) else {
            cache.removeObject(forKey: path as NSString)
            modificationDates[path] = nil
            return nil
        }
        cache.setObject(image, forKey: path as NSString)
        modificationDates[path] = modificationDate
        return image
    }
}

struct VideoWidget: View {
    let layer: StudioLayer
    @StateObject private var playback = VideoPlaybackController()

    var body: some View {
        ZStack {
            Color.black
            PlayerLayerView(player: playback.player)
            if let message = playback.errorMessage {
                ContentUnavailableView("Video unavailable", systemImage: "exclamationmark.triangle", description: Text(message))
                    .padding()
            } else if playback.isLoading {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .onAppear {
            playback.load(path: layer.assetPath)
        }
        .onChange(of: layer.assetPath) { _, newPath in
            playback.load(path: newPath)
        }
        .onDisappear { playback.stop() }
    }
}

@MainActor
final class VideoPlaybackController: ObservableObject {
    let player = AVQueuePlayer()
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?

    private var looper: AVPlayerLooper?
    private var currentURL: URL?
    private var loadTask: Task<Void, Never>?

    init() {
        player.isMuted = true
        player.actionAtItemEnd = .none
    }

    func load(path: String?) {
        guard let path, !path.isEmpty else {
            setFailure("Choose a video file in the Media section.")
            return
        }

        let url = URL(fileURLWithPath: path).standardizedFileURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            setFailure("The file was moved or deleted.")
            return
        }
        guard currentURL != url else {
            player.play()
            return
        }

        clearPlayer(resetURL: false)
        currentURL = url
        isLoading = true
        errorMessage = nil

        loadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let asset = AVURLAsset(url: url)
                let playable = try await asset.load(.isPlayable)
                try Task.checkCancellation()
                guard playable, self.currentURL == url else {
                    self.setFailure("This video format cannot be played on this Mac.")
                    return
                }

                // AVPlayerLooper expects an empty queue. Initializing the queue with
                // the same item and then using it as a template can corrupt its state.
                let item = AVPlayerItem(asset: asset)
                self.looper = AVPlayerLooper(player: self.player, templateItem: item)
                self.isLoading = false
                self.player.play()
            } catch is CancellationError {
                // A newer file replaced this load; no error should be shown.
            } catch {
                self.setFailure("The video could not be opened.")
            }
        }
    }

    func stop() {
        clearPlayer(resetURL: true)
    }

    private func setFailure(_ message: String) {
        clearPlayer(resetURL: true)
        errorMessage = message
    }

    private func clearPlayer(resetURL: Bool) {
        loadTask?.cancel()
        loadTask = nil
        player.pause()
        looper?.disableLooping()
        looper = nil
        player.removeAllItems()
        isLoading = false
        if resetURL { currentURL = nil }
    }
}

final class PlayerSurfaceView: NSView {
    override func makeBackingLayer() -> CALayer { AVPlayerLayer() }

    var playerLayer: AVPlayerLayer {
        layer as! AVPlayerLayer
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        playerLayer.videoGravity = .resizeAspect
        playerLayer.backgroundColor = NSColor.black.cgColor
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        playerLayer.videoGravity = .resizeAspect
        playerLayer.backgroundColor = NSColor.black.cgColor
    }
}

struct PlayerLayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> PlayerSurfaceView {
        let view = PlayerSurfaceView(frame: .zero)
        view.playerLayer.player = player
        return view
    }

    func updateNSView(_ nsView: PlayerSurfaceView, context: Context) {
        if nsView.playerLayer.player !== player {
            nsView.playerLayer.player = player
        }
    }

    static func dismantleNSView(_ nsView: PlayerSurfaceView, coordinator: ()) {
        nsView.playerLayer.player = nil
    }
}

struct VideoOutputCard: View {
    let layer: StudioLayer
    let scale: Double

    var body: some View {
        ZStack {
            Color.black
            VStack(spacing: 12 * scale) {
                Image(systemName: "play.rectangle.fill")
                    .font(.system(size: max(18, 58 * scale)))
                Text(layer.name)
                    .font(.system(size: max(10, 24 * scale), weight: .medium))
                    .lineLimit(1)
            }
            .foregroundStyle(.white.opacity(0.72))
        }
    }
}

struct TemperatureWidget: View {
    let layer: StudioLayer
    let scale: Double
    @ObservedObject private var monitor = HardwareTemperatureMonitor.shared

    var body: some View {
        HStack(spacing: 34 * scale) {
            temperatureColumn("CPU", monitor.cpuTemperature, color: .orange)
            Divider().overlay(.white.opacity(0.12))
            temperatureColumn("GPU", monitor.gpuTemperature, color: .purple)
        }
        .padding(30 * scale)
        .foregroundStyle(Color(studioHex: layer.foregroundHex))
        .onAppear { monitor.refresh() }
    }

    private func temperatureColumn(_ name: String, _ value: Double?, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 7 * scale) {
            Label(name, systemImage: "thermometer.medium")
                .font(.system(size: max(10, 17 * scale), weight: .semibold))
                .foregroundStyle(color)
            Text(value.map { "\(Int($0.rounded()))°C" } ?? "—°C")
                .font(.system(size: max(24, 54 * scale), weight: .semibold, design: .rounded))
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct FPSWidget: View {
    let layer: StudioLayer
    let scale: Double
    @ObservedObject private var monitor = OutputPerformanceMonitor.shared

    var body: some View {
        HStack(spacing: 24 * scale) {
            Image(systemName: "speedometer")
                .font(.system(size: max(24, 64 * scale)))
                .foregroundStyle(monitor.measuredFPS + 1 >= monitor.targetFPS ? .green : .orange)
            VStack(alignment: .leading, spacing: 4 * scale) {
                Text("OUTPUT FPS").font(.system(size: max(9, 15 * scale), weight: .semibold)).foregroundStyle(.secondary)
                Text("\(Int(monitor.measuredFPS.rounded()))")
                    .font(.system(size: max(26, 58 * scale), weight: .semibold, design: .rounded)).monospacedDigit()
                Text("Target \(Int(monitor.targetFPS.rounded()))")
                    .font(.system(size: max(9, 16 * scale), weight: .medium)).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(28 * scale)
        .foregroundStyle(Color(studioHex: layer.foregroundHex))
    }
}

struct WindowCaptureWidget: View {
    let layer: StudioLayer
    @ObservedObject private var monitor = WindowCaptureMonitor.shared
    private var windowID: String { layer.configValue("windowID") }

    var body: some View {
        ZStack {
            Color.black
            if let image = monitor.images[windowID] {
                Image(nsImage: image).resizable().scaledToFit()
            } else {
                ContentUnavailableView("Choose a window", systemImage: "macwindow.on.rectangle", description: Text(monitor.status))
                    .foregroundStyle(.white)
                    .padding()
            }
        }
        .onAppear { monitor.start(windowID: windowID) }
        .onChange(of: windowID) { old, new in monitor.stop(windowID: old); monitor.start(windowID: new) }
        .onDisappear { monitor.stop(windowID: windowID) }
    }
}

struct TextWidget: View {
    let layer: StudioLayer
    let scale: Double
    var body: some View {
        Text(layer.text)
            .font(textFont)
            .foregroundStyle(Color(studioHex: layer.foregroundHex))
            .multilineTextAlignment(.center)
            .padding(22 * scale)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var textFont: Font {
        let size = max(10, layer.fontSize * scale)
        if let fontName = layer.fontName, !fontName.isEmpty {
            return .custom(fontName, size: size)
        }
        return .system(size: size, weight: .semibold, design: .rounded)
    }
}

struct NowPlayingWidget: View {
    let layer: StudioLayer
    let scale: Double
    @ObservedObject private var monitor = NowPlayingMonitor.shared

    var body: some View {
        HStack(spacing: 24 * scale) {
            Group {
                if let artwork = monitor.artwork {
                    Image(nsImage: artwork).resizable().scaledToFill()
                } else {
                    LinearGradient(colors: [.indigo, .blue, .purple], startPoint: .topLeading, endPoint: .bottomTrailing)
                        .overlay(Image(systemName: "music.note").font(.system(size: max(20, 64 * scale))).foregroundStyle(.white))
                }
            }
            .frame(width: 150 * scale, height: 150 * scale)
            .clipShape(RoundedRectangle(cornerRadius: 22 * scale))
            VStack(alignment: .leading, spacing: 9 * scale) {
                HStack {
                    Text(monitor.source.isEmpty ? "NOW PLAYING" : monitor.source.uppercased())
                        .font(.system(size: max(9, 17 * scale), weight: .semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Image(systemName: "waveform")
                        .foregroundStyle(monitor.source.isEmpty ? Color.secondary : Color.blue)
                }
                Text(monitor.title)
                    .font(.system(size: max(15, 34 * scale), weight: .semibold, design: .rounded))
                    .lineLimit(2)
                Text(monitor.artist)
                    .font(.system(size: max(10, 20 * scale), weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color(studioHex: layer.foregroundHex).opacity(0.18))
                        Capsule()
                            .fill(Color(studioHex: layer.foregroundHex))
                            .frame(width: proxy.size.width * min(max(monitor.progress, 0), 1))
                    }
                }
                .frame(height: max(6, 8 * scale))
                HStack {
                    Text(Self.timeLabel(monitor.position))
                    Spacer()
                    Text(Self.timeLabel(monitor.duration))
                }
                .font(.system(size: max(8, 13 * scale), design: .monospaced))
                .foregroundStyle(.secondary)
            }
        }
        .foregroundStyle(Color(studioHex: layer.foregroundHex))
        .padding(30 * scale)
    }

    private static func timeLabel(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded(.down))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

struct LyricsWidget: View {
    let layer: StudioLayer
    let scale: Double
    @ObservedObject private var monitor = NowPlayingMonitor.shared

    var body: some View {
        VStack(spacing: max(3, 6 * scale)) {
            if displayLines.isEmpty {
                Text(fallbackText)
                    .font(.system(size: max(16, layer.fontSize * 0.72 * scale), weight: .semibold, design: .rounded))
                    .multilineTextAlignment(.center)
            } else {
                ForEach(displayLines, id: \.index) { item in
                    Text(item.line.text)
                        .font(.system(size: max(12, layer.fontSize * (item.isCurrent ? 0.82 : 0.55) * scale), weight: item.isCurrent ? .bold : .semibold, design: .rounded))
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .opacity(item.isCurrent ? 1 : (abs(item.distance) == 1 ? 0.42 : 0.20))
                        .scaleEffect(item.isCurrent ? 1 : 0.94)
                        .animation(.easeInOut(duration: 0.24), value: currentIndex)
                }
            }
            Text("\(monitor.title)  •  \(monitor.artist)")
                .font(.system(size: max(8, 15 * scale), weight: .medium))
                .opacity(0.46)
                .lineLimit(1)
        }
        .foregroundStyle(Color(studioHex: layer.foregroundHex))
        .padding(.horizontal, 30 * scale)
        .padding(.vertical, 18 * scale)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var activeLines: [LyricLine] {
        if let path = layer.assetPath,
           let contents = try? String(contentsOfFile: path, encoding: .utf8) {
            return Self.parseLRC(contents)
        }
        return monitor.lyricLines
    }

    private var currentIndex: Int {
        guard !activeLines.isEmpty else { return 0 }
        return activeLines.lastIndex(where: { $0.time <= monitor.position + 0.08 }) ?? 0
    }

    private var displayLines: [(index: Int, line: LyricLine, distance: Int, isCurrent: Bool)] {
        guard !activeLines.isEmpty else { return [] }
        let lower = max(0, currentIndex - 2), upper = min(activeLines.count - 1, currentIndex + 2)
        return (lower...upper).map { ($0, activeLines[$0], $0 - currentIndex, $0 == currentIndex) }
    }

    private var fallbackText: String {
        if let plain = monitor.plainLyrics?.split(separator: "\n").first { return String(plain) }
        return monitor.lyricsStatus
    }

    private static func parseLRC(_ contents: String) -> [LyricLine] {
        let lines: [(Double, String)] = contents.split(separator: "\n").compactMap { rawLine in
            let line = String(rawLine)
            guard let open = line.firstIndex(of: "["), let close = line.firstIndex(of: "]"), close > open else { return nil }
            let stamp = line[line.index(after: open)..<close].split(separator: ":")
            guard stamp.count == 2, let minute = Double(stamp[0]), let second = Double(stamp[1]) else { return nil }
            let text = String(line[line.index(after: close)...]).trimmingCharacters(in: .whitespaces)
            return (minute * 60 + second, text)
        }.sorted { $0.0 < $1.0 }
        return lines.map { LyricLine(time: $0.0, text: $0.1) }
    }
}

struct SystemMonitorWidget: View {
    let layer: StudioLayer
    let scale: Double
    @ObservedObject private var monitor = SystemMetricsMonitor.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 20 * scale) {
            Label("MAC PERFORMANCE", systemImage: "gauge.with.dots.needle.67percent")
                .font(.system(size: max(9, 18 * scale), weight: .semibold))
                .foregroundStyle(.secondary)
            HStack(spacing: 18 * scale) {
                metric("CPU", monitor.snapshot.cpuPercent, .blue)
                metric("RAM", monitor.snapshot.memoryPercent, .purple)
                metric("GPU", monitor.snapshot.gpuPercent, .green)
            }
        }
        .padding(28 * scale)
        .foregroundStyle(Color(studioHex: layer.foregroundHex))
    }

    private func metric(_ name: String, _ value: Double, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 8 * scale) {
            Text(name).font(.system(size: max(8, 16 * scale), weight: .semibold)).foregroundStyle(.secondary)
            Text("\(Int(value.rounded()))%")
                .font(.system(size: max(16, 38 * scale), weight: .semibold, design: .rounded))
                .monospacedDigit()
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(.primary.opacity(0.1))
                    Capsule().fill(color.gradient).frame(width: proxy.size.width * min(max(value / 100, 0), 1))
                }
            }
            .frame(height: max(5, 9 * scale))
        }
        .frame(maxWidth: .infinity)
    }
}

struct PowerSupplyWidget: View {
    let layer: StudioLayer
    let scale: Double
    @ObservedObject private var monitor = PSUMonitor.shared

    private var telemetry: PSUTelemetrySnapshot { monitor.snapshot }
    private var live: Bool { telemetry.connected && !monitor.isStale }

    var body: some View {
        GeometryReader { proxy in
            let compact = proxy.size.width < 390 || proxy.size.height < 220
            let wide = proxy.size.width / max(proxy.size.height, 1) > 2.25
            let padding = max(13, min(28, min(proxy.size.width, proxy.size.height) * 0.075))

            VStack(alignment: .leading, spacing: max(8, 14 * scale)) {
                header(compact: compact)
                if telemetry.updatedAt == nil {
                    unavailable
                } else if wide {
                    HStack(spacing: max(14, 24 * scale)) {
                        primaryReading(compact: compact)
                            .frame(width: proxy.size.width * 0.24, alignment: .leading)
                        rails(compact: true)
                        health(compact: true)
                            .frame(width: proxy.size.width * 0.22, alignment: .leading)
                    }
                } else {
                    HStack(alignment: .top, spacing: max(14, 24 * scale)) {
                        primaryReading(compact: compact)
                        health(compact: compact)
                    }
                    rails(compact: compact)
                }
            }
            .padding(padding)
            .foregroundStyle(Color(studioHex: layer.foregroundHex))
        }
    }

    private func header(compact: Bool) -> some View {
        HStack(spacing: 8 * scale) {
            Image(systemName: "bolt.horizontal.circle.fill")
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.orange)
            Text(compact ? "VD1200P" : "POWER SUPPLY")
                .font(.system(size: max(9, 16 * scale), weight: .semibold))
            Spacer(minLength: 4)
            Circle()
                .fill(live ? Color.green : Color.orange)
                .frame(width: max(6, 9 * scale), height: max(6, 9 * scale))
            Text(live ? "LIVE" : "OFFLINE")
                .font(.system(size: max(7, 11 * scale), weight: .bold))
                .foregroundStyle(.secondary)
        }
    }

    private func primaryReading(compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: max(1, 3 * scale)) {
            HStack(alignment: .firstTextBaseline, spacing: 3 * scale) {
                Text("\(Int(telemetry.inputPowerWatts.rounded()))")
                    .font(.system(size: max(24, (compact ? 43 : 58) * scale), weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text("W")
                    .font(.system(size: max(10, 18 * scale), weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            Text("AC INPUT")
                .font(.system(size: max(7, 11 * scale), weight: .bold))
                .foregroundStyle(.secondary)
        }
    }

    private func rails(compact: Bool) -> some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: 8 * scale), count: compact ? 4 : 2)
        return LazyVGrid(columns: columns, spacing: 8 * scale) {
            rail("3.3V", telemetry.rail3V3Volts, telemetry.rail3V3Amps)
            rail("5V", telemetry.rail5VVolts, telemetry.rail5VAmps)
            rail(layer.configValue("rail12ALabel", fallback: "12V Channel A"), telemetry.rail12AVolts, telemetry.rail12AAmps)
            rail(layer.configValue("rail12BLabel", fallback: "12V Channel B"), telemetry.rail12BVolts, telemetry.rail12BAmps)
        }
        .frame(maxWidth: .infinity)
    }

    private func rail(_ label: String, _ volts: Double, _ amps: Double) -> some View {
        VStack(alignment: .leading, spacing: max(2, 4 * scale)) {
            Text(label.uppercased())
                .font(.system(size: max(7, 10 * scale), weight: .bold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(String(format: "%.2f V", volts))
                .font(.system(size: max(11, 20 * scale), weight: .semibold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.72)
            Text(String(format: "%.2f A", amps))
                .font(.system(size: max(7, 11 * scale), weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.horizontal, max(7, 10 * scale))
        .padding(.vertical, max(5, 8 * scale))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.primary.opacity(0.065), in: RoundedRectangle(cornerRadius: max(7, 12 * scale), style: .continuous))
    }

    private func health(compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: max(5, 9 * scale)) {
            healthLine("fan.fill", "\(Int(telemetry.fanRPM.rounded())) RPM", .blue)
            healthLine("thermometer.medium", String(format: "%.1f°C", telemetry.temperatureCelsius), .orange)
            healthLine("powerplug.fill", String(format: "%.1f V AC", telemetry.inputVolts), .green)
            if !compact, !telemetry.firmware.isEmpty {
                Text(telemetry.firmware)
                    .font(.system(size: max(7, 10 * scale), design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func healthLine(_ symbol: String, _ value: String, _ color: Color) -> some View {
        Label {
            Text(value)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        } icon: {
            Image(systemName: symbol).foregroundStyle(color)
        }
        .font(.system(size: max(8, 14 * scale), weight: .medium, design: .rounded))
    }

    private var unavailable: some View {
        VStack(spacing: 8 * scale) {
            Image(systemName: "cable.connector.slash")
                .font(.system(size: max(22, 42 * scale), weight: .light))
                .foregroundStyle(.secondary)
            Text("Connect the VD1200P Type-C telemetry cable")
                .font(.system(size: max(10, 17 * scale), weight: .medium))
                .multilineTextAlignment(.center)
            Text(monitor.status)
                .font(.system(size: max(7, 11 * scale)))
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct NetworkSpeedWidget: View {
    let layer: StudioLayer
    let scale: Double
    @ObservedObject private var monitor = SystemMetricsMonitor.shared

    var body: some View {
        HStack(spacing: 34 * scale) {
            rate("DOWNLOAD", "arrow.down", monitor.snapshot.downloadBytesPerSecond, .blue)
            Divider().opacity(0.3)
            rate("UPLOAD", "arrow.up", monitor.snapshot.uploadBytesPerSecond, .purple)
        }
        .padding(30 * scale)
        .foregroundStyle(Color(studioHex: layer.foregroundHex))
    }

    private func rate(_ title: String, _ symbol: String, _ value: Double, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 10 * scale) {
            Label(title, systemImage: symbol)
                .font(.system(size: max(9, 16 * scale), weight: .semibold))
                .foregroundStyle(color)
            Text(formattedRate(value))
                .font(.system(size: max(16, 38 * scale), weight: .semibold, design: .rounded))
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct AirPodsWidget: View {
    let layer: StudioLayer
    let scale: Double
    @ObservedObject private var monitor = AirPodsMonitor.shared

    var body: some View {
        VStack(spacing: 14 * scale) {
            Image(systemName: "airpodspro")
                .font(.system(size: max(28, 82 * scale), weight: .light))
                .symbolEffect(.bounce, value: monitor.connectionSequence)
            Text(monitor.connectedName ?? "AirPods")
                .font(.system(size: max(14, 30 * scale), weight: .semibold, design: .rounded))
            Label(monitor.connectedName == nil ? "Not connected" : "Connected", systemImage: monitor.connectedName == nil ? "circle" : "checkmark.circle.fill")
                .font(.system(size: max(9, 17 * scale), weight: .medium))
                .foregroundStyle(monitor.connectedName == nil ? Color.secondary : Color.green)
        }
        .foregroundStyle(Color(studioHex: layer.foregroundHex))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24 * scale)
    }
}

struct FocusTimerWidget: View {
    let layer: StudioLayer
    let scale: Double

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let end = layer.numberValue("endTime")
            let minutes = layer.numberValue("minutes", fallback: 25)
            let remaining = end > context.date.timeIntervalSince1970
                ? end - context.date.timeIntervalSince1970
                : minutes * 60
            VStack(spacing: 10 * scale) {
                Text(layer.text).font(.system(size: max(10, 18 * scale), weight: .semibold)).foregroundStyle(.secondary)
                Text(timeString(remaining))
                    .font(.system(size: max(30, 76 * scale), weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text(end > 0 ? "Stay focused" : "Ready")
                    .font(.system(size: max(9, 17 * scale), weight: .medium)).foregroundStyle(.secondary)
            }
            .foregroundStyle(Color(studioHex: layer.foregroundHex))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func timeString(_ seconds: Double) -> String {
        String(format: "%02d:%02d", max(0, Int(seconds)) / 60, max(0, Int(seconds)) % 60)
    }
}

struct WorldClockWidget: View {
    let layer: StudioLayer
    let scale: Double

    private var zones: [(String, String)] {
        [
            (layer.configValue("clockCity1", fallback: "Shanghai"), layer.configValue("clockZone1", fallback: "Asia/Shanghai")),
            (layer.configValue("clockCity2", fallback: "London"), layer.configValue("clockZone2", fallback: "Europe/London")),
            (layer.configValue("clockCity3", fallback: "New York"), layer.configValue("clockZone3", fallback: "America/New_York"))
        ].filter { !$0.0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            HStack(spacing: 18 * scale) {
                ForEach(Array(zones.enumerated()), id: \.offset) { _, zone in
                    VStack(spacing: 7 * scale) {
                        Text(zone.0.uppercased()).font(.system(size: max(8, 14 * scale), weight: .semibold)).foregroundStyle(.secondary)
                        Text(time(context.date, zone: zone.1))
                            .font(.system(size: max(15, 31 * scale), weight: .semibold, design: .rounded)).monospacedDigit()
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .foregroundStyle(Color(studioHex: layer.foregroundHex))
            .padding(26 * scale)
        }
    }

    private func time(_ date: Date, zone: String) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        formatter.timeZone = TimeZone(identifier: zone)
        return formatter.string(from: date)
    }
}

struct CalendarWidget: View {
    let layer: StudioLayer
    let scale: Double
    @ObservedObject private var agenda = AgendaMonitor.shared

    var body: some View {
        HStack(spacing: 24 * scale) {
            VStack(spacing: 2 * scale) {
                Text(dayNumber).font(.system(size: max(28, 68 * scale), weight: .semibold, design: .rounded))
                Text(month).font(.system(size: max(9, 16 * scale), weight: .bold)).foregroundStyle(.red)
            }
            .frame(width: 120 * scale, height: 120 * scale)
            .background(.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 20 * scale))
            VStack(alignment: .leading, spacing: 8 * scale) {
                Text("UP NEXT").font(.system(size: max(8, 15 * scale), weight: .semibold)).foregroundStyle(.secondary)
                Text(agenda.nextEventTitle)
                    .font(.system(size: max(15, 32 * scale), weight: .semibold, design: .rounded))
                    .lineLimit(2)
                Text(eventTime)
                    .font(.system(size: max(9, 18 * scale), weight: .medium))
                    .foregroundStyle(agenda.calendarAccessDenied ? .red : .secondary)
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(Color(studioHex: layer.foregroundHex))
        .padding(28 * scale)
        .onAppear { agenda.connectCalendar() }
    }

    private var eventDate: Date { agenda.nextEventDate ?? Date() }
    private var dayNumber: String { eventDate.formatted(.dateTime.day()) }
    private var month: String { eventDate.formatted(.dateTime.month(.abbreviated)).uppercased() }
    private var eventTime: String {
        if agenda.calendarAccessDenied { return "Calendar access is off" }
        return agenda.nextEventDate?.formatted(.dateTime.weekday(.abbreviated).hour().minute()) ?? "Open the widget to connect"
    }
}

struct RemindersWidget: View {
    let layer: StudioLayer
    let scale: Double
    @ObservedObject private var agenda = AgendaMonitor.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10 * scale) {
            HStack {
                Label("REMINDERS", systemImage: "checklist")
                    .font(.system(size: max(9, 17 * scale), weight: .semibold))
                    .foregroundStyle(.blue)
                Spacer()
                Text("\(agenda.reminders.count)")
                    .font(.system(size: max(9, 17 * scale), weight: .semibold)).foregroundStyle(.secondary)
            }
            if agenda.reminderAccessDenied {
                Text("Reminders access is off").foregroundStyle(.red)
            } else if agenda.reminders.isEmpty {
                Text("No incomplete reminders")
                    .font(.system(size: max(13, 27 * scale), weight: .semibold, design: .rounded))
            } else {
                ForEach(Array(agenda.reminders.prefix(3).enumerated()), id: \.offset) { _, title in
                    Label(title, systemImage: "circle")
                        .font(.system(size: max(9, 18 * scale), weight: .medium))
                        .lineLimit(1)
                }
            }
        }
        .foregroundStyle(Color(studioHex: layer.foregroundHex))
        .padding(28 * scale)
        .onAppear { agenda.connectReminders() }
    }
}

struct AudioVisualizerWidget: View {
    let layer: StudioLayer
    let scale: Double
    @ObservedObject private var audio = AudioLevelMonitor.shared

    var body: some View {
        HStack(alignment: .center, spacing: 7 * scale) {
            ForEach(Array(audio.levels.enumerated()), id: \.offset) { _, level in
                Capsule()
                    .fill(LinearGradient(colors: [.blue, .purple], startPoint: .bottom, endPoint: .top))
                    .frame(width: max(4, 12 * scale), height: max(10, level * 190 * scale))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(28 * scale)
        .onAppear { audio.start() }
    }
}

struct NewsFeedWidget: View {
    let layer: StudioLayer
    let scale: Double
    @ObservedObject private var news = NewsFeedMonitor.shared

    private var feedURL: String { layer.configValue("url", fallback: "https://techcrunch.com/feed/") }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 7)) { context in
            let headlines = news.headlines(for: feedURL)
            let index = headlines.isEmpty ? 0 : Int(context.date.timeIntervalSince1970 / 7) % headlines.count
            HStack(spacing: 24 * scale) {
                Image(systemName: "newspaper.fill")
                    .font(.system(size: max(24, 60 * scale)))
                    .foregroundStyle(.blue)
                VStack(alignment: .leading, spacing: 9 * scale) {
                    Text(layer.configValue("source", fallback: "NEWS").uppercased())
                        .font(.system(size: max(8, 16 * scale), weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text(headlines.isEmpty ? (news.errors[feedURL] ?? "Loading headlines…") : headlines[index].title)
                        .font(.system(size: max(14, 30 * scale), weight: .semibold, design: .rounded))
                        .lineLimit(3)
                }
                Spacer(minLength: 0)
            }
            .padding(28 * scale)
            .foregroundStyle(Color(studioHex: layer.foregroundHex))
        }
        .onAppear { news.refresh(feedURL) }
        .onChange(of: feedURL) { _, url in news.refresh(url) }
    }
}

struct GenericInfoWidget: View {
    let layer: StudioLayer
    let scale: Double

    var body: some View {
        HStack(spacing: 22 * scale) {
            Image(systemName: layer.kind.symbol)
                .font(.system(size: max(22, 58 * scale), weight: .medium))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.blue)
                .frame(width: 90 * scale)
            VStack(alignment: .leading, spacing: 8 * scale) {
                Text(layer.kind.title.uppercased())
                    .font(.system(size: max(8, 15 * scale), weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(layer.text)
                    .font(.system(size: max(14, 32 * scale), weight: .semibold, design: .rounded))
                    .lineLimit(2)
                if !layer.configValue("subtitle").isEmpty {
                    Text(layer.configValue("subtitle"))
                        .font(.system(size: max(9, 17 * scale), weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 0)
            if !layer.configValue("value").isEmpty {
                Text(layer.configValue("value"))
                    .font(.system(size: max(16, 38 * scale), weight: .semibold, design: .rounded))
                    .monospacedDigit()
            }
        }
        .foregroundStyle(Color(studioHex: layer.foregroundHex))
        .padding(28 * scale)
    }
}

struct EnvironmentWidget: View {
    let layer: StudioLayer
    let scale: Double
    @ObservedObject private var monitor = CurrentEnvironmentMonitor.shared

    var body: some View {
        HStack(spacing: 24 * scale) {
            Image(systemName: "location.fill.viewfinder")
                .font(.system(size: max(24, 62 * scale)))
                .foregroundStyle(.green)
            VStack(alignment: .leading, spacing: 8 * scale) {
                Text(monitor.snapshot.place.uppercased())
                    .font(.system(size: max(8, 15 * scale), weight: .semibold))
                    .foregroundStyle(.secondary).lineLimit(1)
                Text(monitor.snapshot.temperature.map { "\(Int($0.rounded()))°C" } ?? "Local weather")
                    .font(.system(size: max(18, 42 * scale), weight: .semibold, design: .rounded))
                HStack(spacing: 16 * scale) {
                    if let value = monitor.snapshot.feelsLike { Label("Feels \(Int(value.rounded()))°", systemImage: "thermometer.medium") }
                    if let value = monitor.snapshot.humidity { Label("\(Int(value.rounded()))%", systemImage: "humidity.fill") }
                    if let value = monitor.snapshot.wind { Label("\(Int(value.rounded())) km/h", systemImage: "wind") }
                }
                .font(.system(size: max(8, 15 * scale), weight: .medium))
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(Color(studioHex: layer.foregroundHex))
        .padding(28 * scale)
        .onAppear { monitor.requestLocation() }
    }
}

struct ScreenTimeWidget: View {
    let layer: StudioLayer
    let scale: Double
    @ObservedObject private var monitor = ScreenTimeMonitor.shared
    private let colors: [Color] = [.blue, .purple, .pink, .orange]

    var body: some View {
        VStack(alignment: .leading, spacing: 14 * scale) {
            HStack {
                VStack(alignment: .leading, spacing: 2 * scale) {
                    Text("TODAY").font(.system(size: max(8, 14 * scale), weight: .semibold)).foregroundStyle(.secondary)
                    Text(duration(monitor.totalSeconds)).font(.system(size: max(18, 40 * scale), weight: .semibold, design: .rounded))
                }
                Spacer()
                Image(systemName: "hourglass.circle.fill").font(.system(size: max(22, 44 * scale))).foregroundStyle(.blue)
            }
            GeometryReader { proxy in
                HStack(spacing: 3 * scale) {
                    ForEach(Array(monitor.topApps.enumerated()), id: \.offset) { item in
                        RoundedRectangle(cornerRadius: 4 * scale)
                            .fill(colors[item.offset % colors.count])
                            .frame(width: barWidth(seconds: item.element.1, available: proxy.size.width))
                    }
                }
            }.frame(height: max(8, 14 * scale))
            ForEach(Array(monitor.topApps.enumerated()), id: \.offset) { item in
                HStack {
                    Circle().fill(colors[item.offset % colors.count]).frame(width: 8 * scale, height: 8 * scale)
                    Text(item.element.0).lineLimit(1)
                    Spacer()
                    Text(duration(item.element.1)).monospacedDigit().foregroundStyle(.secondary)
                }
                .font(.system(size: max(8, 14 * scale), weight: .medium))
            }
        }
        .foregroundStyle(Color(studioHex: layer.foregroundHex))
        .padding(26 * scale)
    }

    private func duration(_ seconds: Double) -> String {
        let minutes = Int(seconds) / 60
        return minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes)m"
    }

    private func barWidth(seconds: Double, available: Double) -> Double {
        max(4, available * seconds / max(monitor.totalSeconds, 1))
    }
}

struct YouTubeWidget: View {
    let layer: StudioLayer
    @StateObject private var playback = YouTubePlaybackController()

    var body: some View {
        ZStack {
            Color.black
            PlayerLayerView(player: playback.player)
            if playback.needsSupport {
                VStack(spacing: 10) {
                    Image(systemName: "play.tv.fill").font(.system(size: 32))
                    Text("Enable YouTube Playback").font(.headline)
                    Text("Uses the open-source yt-dlp helper to avoid embedded-browser errors.")
                        .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Button(playback.installing ? "Installing…" : "Install YouTube Support") { playback.installSupport() }
                        .buttonStyle(.borderedProminent)
                        .disabled(playback.installing)
                }
                .padding(20)
                .foregroundStyle(.white)
            } else if playback.loading {
                ProgressView("Preparing video…").tint(.white).foregroundStyle(.white)
            } else if let error = playback.errorMessage {
                ContentUnavailableView("YouTube unavailable", systemImage: "exclamationmark.triangle", description: Text(error))
                    .foregroundStyle(.white).padding()
            }
        }
        .onAppear { load() }
        .onChange(of: layer.configValue("url")) { _, _ in load() }
        .onChange(of: layer.configValue("cookiesBrowser", fallback: "none")) { _, _ in load() }
        .onChange(of: layer.configValue("cookiesFile")) { _, _ in load() }
        .onDisappear { playback.stop() }
    }

    private func load() {
        playback.load(
            layer.configValue("url"),
            cookiesFromBrowser: layer.configValue("cookiesBrowser", fallback: "none"),
            cookiesFile: layer.configValue("cookiesFile")
        )
    }
}

@MainActor
final class YouTubePlaybackController: ObservableObject {
    let player = AVPlayer()
    @Published private(set) var needsSupport = false
    @Published private(set) var installing = false
    @Published private(set) var loading = false
    @Published private(set) var errorMessage: String?
    private var task: Task<Void, Never>?
    private var endObserver: NSObjectProtocol?
    private var statusObserver: NSKeyValueObservation?
    private var currentInput = ""

    func load(_ input: String, cookiesFromBrowser: String = "none", cookiesFile: String = "") {
        let requestIdentity = input + "|" + cookiesFromBrowser + "|" + cookiesFile
        guard requestIdentity != currentInput || player.currentItem == nil else { player.play(); return }
        currentInput = requestIdentity
        task?.cancel()
        statusObserver?.invalidate()
        statusObserver = nil
        player.pause()
        player.replaceCurrentItem(with: nil)
        errorMessage = nil
        guard let tools = YouTubeMediaResolver.tools else {
            needsSupport = true
            loading = false
            return
        }
        needsSupport = false
        loading = true
        task = Task { [weak self] in
            let resolved = await YouTubeMediaResolver.resolveStream(input, tools: tools, cookiesFromBrowser: cookiesFromBrowser, cookiesFile: cookiesFile)
            guard let self, !Task.isCancelled else { return }
            switch resolved {
            case .success(let url):
                let item = AVPlayerItem(url: url)
                item.preferredForwardBufferDuration = 3
                player.replaceCurrentItem(with: item)
                if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
                endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak playbackPlayer = self.player] _ in
                    playbackPlayer?.seek(to: .zero)
                    playbackPlayer?.play()
                }
                statusObserver?.invalidate()
                statusObserver = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
                    Task { @MainActor in
                        guard let self, self.player.currentItem === item else { return }
                        switch item.status {
                        case .readyToPlay:
                            self.loading = false
                            self.errorMessage = nil
                            self.player.play()
                        case .failed:
                            self.loading = false
                            self.errorMessage = item.error?.localizedDescription ?? "The YouTube stream could not be played."
                        case .unknown:
                            self.loading = true
                        @unknown default:
                            self.loading = false
                            self.errorMessage = "The YouTube stream could not be played."
                        }
                    }
                }
                player.isMuted = true
                player.play()
            case .failure(let error):
                loading = false
                errorMessage = error.localizedDescription
            }
        }
    }

    func installSupport() {
        guard !installing else { return }
        let brew = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"].first(where: FileManager.default.fileExists(atPath:))
        guard let brew else {
            errorMessage = "Homebrew is required. Install yt-dlp, then reopen the widget."
            return
        }
        let requested = currentInput.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
        installing = true
        Task {
            let success = await YouTubeMediaResolver.run(executable: brew, arguments: ["install", "yt-dlp", "deno"]).0 == 0
            installing = false
            if success { currentInput = ""; load(requested.first ?? "", cookiesFromBrowser: requested.count > 1 ? requested[1] : "none", cookiesFile: requested.count > 2 ? requested[2] : "") }
            else { errorMessage = "Homebrew could not install yt-dlp." }
        }
    }

    func stop() {
        task?.cancel()
        player.pause()
        player.replaceCurrentItem(with: nil)
        statusObserver?.invalidate()
        statusObserver = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
    }

}

enum YouTubeMediaResolver {
    struct Tools: Sendable {
        let downloader: String
        let javascriptRuntime: String?
        let ffmpeg: String?
    }

    static var tools: Tools? {
        guard let downloader = ["/opt/homebrew/bin/yt-dlp", "/usr/local/bin/yt-dlp"].first(where: FileManager.default.isExecutableFile(atPath:)) else { return nil }
        let javascriptRuntime = ["/opt/homebrew/bin/deno", "/usr/local/bin/deno"].first(where: FileManager.default.isExecutableFile(atPath:))
        let ffmpeg = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"].first(where: FileManager.default.isExecutableFile(atPath:))
        return Tools(downloader: downloader, javascriptRuntime: javascriptRuntime, ffmpeg: ffmpeg)
    }

    static var persistentCookiesURL: URL? {
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let folder = support.appendingPathComponent("SubScreenStudio/YouTube", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("session-cookies.txt")
    }

    static var hasPersistentSession: Bool {
        guard let path = persistentCookiesURL?.path else { return false }
        let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.intValue ?? 0
        return size > 100
    }

    nonisolated static func resolveStream(_ input: String, tools: Tools, cookiesFromBrowser: String = "none", cookiesFile: String = "") async -> Result<URL, Error> {
        // AVPlayer supports HLS natively but does not support YouTube's MPEG-DASH
        // video-only URLs reliably. Prefer an H.264 HLS rendition, then fall back
        // through current YouTube formats instead of requiring a combined MP4.
        let selector = "bestvideo[protocol^=m3u8][vcodec^=avc1][height<=480]/bestvideo[protocol^=m3u8][height<=480]/bestvideo[ext=mp4][vcodec^=avc1][height<=480]/bestvideo[height<=480]/best"
        let arguments = commonArguments(tools, cookiesFromBrowser: cookiesFromBrowser, cookiesFile: cookiesFile) + ["-g", "-f", selector, input]
        let result = await run(executable: tools.downloader, arguments: arguments)
        if result.0 == 0,
           let first = result.1.split(separator: "\n").first,
           let url = URL(string: String(first)) { return .success(url) }

        // A public video is attempted without touching browser data. Only when
        // YouTube explicitly asks for sign-in do we look through installed
        // browsers, save the first working session, and retry once.
        let needsAccount = result.1.localizedCaseInsensitiveContains("sign in to confirm") || result.1.localizedCaseInsensitiveContains("not a bot")
        let browserAccessFailed = result.1.localizedCaseInsensitiveContains("operation not permitted") || result.1.localizedCaseInsensitiveContains("could not copy")
        let mayAutoDetect = cookiesFile.isEmpty && !hasPersistentSession && cookiesFromBrowser != "none"
        if (needsAccount || browserAccessFailed), mayAutoDetect,
           case .success = await captureBrowserSession(browser: "auto", input: input, tools: tools) {
            let retry = await run(executable: tools.downloader, arguments: commonArguments(tools, cookiesFromBrowser: "none", cookiesFile: "") + ["-g", "-f", selector, input])
            if retry.0 == 0,
               let first = retry.1.split(separator: "\n").first,
               let url = URL(string: String(first)) { return .success(url) }
            return .failure(playbackError(retry))
        }
        return .failure(playbackError(result))
    }

    nonisolated static func downloadVideo(_ input: String, tools: Tools, cookiesFromBrowser: String = "none", cookiesFile: String = "") async -> Result<URL, Error> {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("SubScreenStudio-YouTube-\(UUID().uuidString)")
        let template = base.path + ".%(ext)s"
        let h264Video = "bestvideo[ext=mp4][vcodec^=avc1][height<=480]"
        let selector: String
        if tools.ffmpeg != nil {
            selector = "\(h264Video)+bestaudio[ext=m4a]/\(h264Video)/best[ext=mp4]/best"
        } else {
            selector = "\(h264Video)/bestvideo[ext=mp4][height<=480]/bestvideo[height<=480]/best"
        }
        var arguments = commonArguments(tools, cookiesFromBrowser: cookiesFromBrowser, cookiesFile: cookiesFile)
        if let ffmpeg = tools.ffmpeg {
            arguments += ["--ffmpeg-location", ffmpeg, "--merge-output-format", "mp4"]
        }
        arguments += ["-f", selector, "-o", template, "--print", "after_move:filepath", input]
        let result = await run(executable: tools.downloader, arguments: arguments)
        guard result.0 == 0,
              let last = result.1.split(separator: "\n").last,
              FileManager.default.fileExists(atPath: String(last)) else { return .failure(playbackError(result)) }
        return .success(URL(fileURLWithPath: String(last)))
    }

    nonisolated static func captureBrowserSession(browser: String, input: String, tools: Tools) async -> Result<URL, Error> {
        let candidates = browser == "auto" ? availableCookieBrowsers : [browser]
        guard !candidates.isEmpty, browser != "none", !browser.isEmpty else {
            return .failure(NSError(domain: "YouTube", code: -1, userInfo: [NSLocalizedDescriptionKey: "Choose the browser where YouTube is already signed in."]))
        }
        var lastError: Error?
        for candidate in candidates {
            let result = await captureBrowserSession(from: candidate, input: input, tools: tools)
            if case .success = result { return result }
            if case .failure(let error) = result { lastError = error }
        }
        return .failure(lastError ?? NSError(domain: "YouTube", code: -1, userInfo: [NSLocalizedDescriptionKey: "No signed-in YouTube browser session was found."]))
    }

    nonisolated private static func captureBrowserSession(from browser: String, input: String, tools: Tools) async -> Result<URL, Error> {
        guard let destination = persistentCookiesURL else {
            return .failure(NSError(domain: "YouTube", code: -1, userInfo: [NSLocalizedDescriptionKey: "The local YouTube session folder is unavailable."]))
        }
        let temporary = destination.deletingLastPathComponent().appendingPathComponent("session-cookies-new.txt")
        try? FileManager.default.removeItem(at: temporary)
        var arguments = ["--no-playlist", "--no-warnings", "--cookies-from-browser", browser, "--cookies", temporary.path]
        if let runtime = tools.javascriptRuntime {
            arguments += ["--js-runtimes", "deno:\(runtime)", "--remote-components", "ejs:github"]
        }
        arguments += ["--simulate", "--skip-download", input]
        let result = await run(executable: tools.downloader, arguments: arguments)
        guard result.0 == 0, FileManager.default.fileExists(atPath: temporary.path) else {
            return .failure(playbackError(result))
        }
        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: temporary, to: destination)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
            return .success(destination)
        } catch {
            return .failure(error)
        }
    }

    nonisolated private static var availableCookieBrowsers: [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let paths: [(String, String)] = [
            ("chrome", "Library/Application Support/Google/Chrome"),
            ("edge", "Library/Application Support/Microsoft Edge"),
            ("brave", "Library/Application Support/BraveSoftware/Brave-Browser"),
            ("firefox", "Library/Application Support/Firefox/Profiles"),
            ("safari", "Library/Containers/com.apple.Safari/Data/Library/Cookies")
        ]
        return paths.compactMap { browser, path in
            FileManager.default.fileExists(atPath: home.appendingPathComponent(path).path) ? browser : nil
        }
    }

    nonisolated private static func commonArguments(_ tools: Tools, cookiesFromBrowser: String = "none", cookiesFile: String = "") -> [String] {
        var arguments = ["--no-playlist", "--no-warnings"]
        if !cookiesFile.isEmpty, FileManager.default.fileExists(atPath: cookiesFile) {
            arguments += ["--cookies", cookiesFile]
        } else if let saved = persistentCookiesURL?.path, hasPersistentSession {
            // A successful browser connection is copied into app support once,
            // so changing videos does not repeatedly query the browser database.
            arguments += ["--cookies", saved]
        } else if cookiesFromBrowser != "none", cookiesFromBrowser != "auto", !cookiesFromBrowser.isEmpty {
            arguments += ["--cookies-from-browser", cookiesFromBrowser]
            if let saved = persistentCookiesURL?.path { arguments += ["--cookies", saved] }
        }
        if let runtime = tools.javascriptRuntime {
            arguments += ["--js-runtimes", "deno:\(runtime)", "--remote-components", "ejs:github"]
        }
        return arguments
    }

    nonisolated private static func playbackError(_ result: (Int32, String)) -> NSError {
        let detail = result.1.split(separator: "\n").suffix(2).joined(separator: " ")
        if result.1.localizedCaseInsensitiveContains("operation not permitted") && result.1.localizedCaseInsensitiveContains("safari") {
            return NSError(domain: "YouTube", code: Int(result.0), userInfo: [NSLocalizedDescriptionKey: "macOS blocked access to Safari’s protected cookies. Grant SubScreen Studio Full Disk Access and reopen it, use Chrome/Firefox, or import a cookies.txt file in the Layer inspector."])
        }
        if result.1.localizedCaseInsensitiveContains("sign in to confirm") || result.1.localizedCaseInsensitiveContains("not a bot") {
            return NSError(domain: "YouTube", code: Int(result.0), userInfo: [NSLocalizedDescriptionKey: "YouTube needs a signed-in session. Choose the browser where you are signed into YouTube in the Layer inspector, then retry."])
        }
        return NSError(domain: "YouTube", code: Int(result.0), userInfo: [NSLocalizedDescriptionKey: detail.isEmpty ? "YouTube playback could not be prepared." : detail])
    }

    nonisolated static func run(executable: String, arguments: [String]) async -> (Int32, String) {
        await Task.detached(priority: .utility) {
            let process = Process()
            let pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.standardOutput = pipe
            process.standardError = pipe
            do {
                try process.run()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                return (process.terminationStatus, String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
            } catch {
                return (-1, error.localizedDescription)
            }
        }.value
    }
}

struct YouTubeWebView: NSViewRepresentable {
    let urlString: String

    final class Coordinator: NSObject, WKNavigationDelegate {
        var loadedInput = ""
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.allowsAirPlayForMediaPlayback = false
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.setValue(false, forKey: "drawsBackground")
        view.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
        view.navigationDelegate = context.coordinator
        load(into: view, coordinator: context.coordinator)
        return view
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        guard context.coordinator.loadedInput != urlString else { return }
        load(into: nsView, coordinator: context.coordinator)
    }

    static func dismantleNSView(_ nsView: WKWebView, coordinator: ()) {
        nsView.stopLoading()
        nsView.loadHTMLString("", baseURL: nil)
    }

    private func load(into view: WKWebView, coordinator: Coordinator) {
        guard let url = playbackURL(from: urlString) else { return }
        coordinator.loadedInput = urlString
        var request = URLRequest(url: url, cachePolicy: .reloadRevalidatingCacheData, timeoutInterval: 20)
        // YouTube rejects embedded players without an identifiable embedding
        // page (error 152/153). A real referrer keeps the official iframe
        // player usable inside WKWebView without scraping video URLs.
        request.setValue("https://www.youtube.com/", forHTTPHeaderField: "Referer")
        request.setValue("https://www.youtube.com", forHTTPHeaderField: "Origin")
        view.load(request)
    }

    private func playbackURL(from input: String) -> URL? {
        guard let source = URL(string: input), let host = source.host?.lowercased() else { return nil }
        var videoID: String?
        if host.contains("youtu.be") {
            videoID = source.pathComponents.dropFirst().first
        } else if host.contains("youtube.com") {
            videoID = URLComponents(url: source, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "v" })?.value
            if videoID == nil, let index = source.pathComponents.firstIndex(of: "shorts"), source.pathComponents.indices.contains(index + 1) {
                videoID = source.pathComponents[index + 1]
            }
        }
        guard let videoID, !videoID.isEmpty else { return source }
        return URL(string: "https://www.youtube.com/embed/\(videoID)?autoplay=1&mute=1&loop=1&playlist=\(videoID)&playsinline=1&controls=1")
    }
}
