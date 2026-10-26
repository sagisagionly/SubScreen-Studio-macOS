import Foundation
import SwiftUI

let studioCanvasSize = CGSize(width: 1920, height: 462)

enum StudioDisplayProfile: String, Codable, CaseIterable, Identifiable {
    case d92
    case dq288

    var id: String { rawValue }

    var title: String {
        switch self {
        case .d92: "D92 Wide Display"
        case .dq288: "2.88-inch Square Display"
        }
    }

    var shortTitle: String {
        switch self {
        case .d92: "D92"
        case .dq288: "2.88-inch"
        }
    }

    var driverID: String { rawValue }

    var maxFPS: Double {
        switch self {
        case .d92: 60
        case .dq288: 30
        }
    }

    var canvasSize: CGSize {
        switch self {
        case .d92: studioCanvasSize
        case .dq288: CGSize(width: 480, height: 480)
        }
    }

    var resolutionText: String {
        "\(Int(canvasSize.width)) × \(Int(canvasSize.height))"
    }
}

enum StudioDisplayRotation: Int, Codable, CaseIterable, Identifiable {
    case degrees0 = 0
    case degrees90 = 90
    case degrees180 = 180
    case degrees270 = 270

    var id: Int { rawValue }
    var title: String { "\(rawValue)°" }
    var swapsCanvasAxes: Bool { self == .degrees90 || self == .degrees270 }
}

enum HorizontalAlignmentChoice { case left, center, right }
enum VerticalAlignmentChoice { case top, middle, bottom }

/// Familiar, repeatable widget families make a scene much easier to compose
/// than asking people to eyeball every rectangle. Custom remains implicit when
/// a layer is freely transformed away from one of these sizes.
enum WidgetSizePreset: String, CaseIterable, Identifiable {
    case small, medium, large, wide

    var id: String { rawValue }

    var title: String {
        switch self {
        case .small: "Small"
        case .medium: "Medium"
        case .large: "Large"
        case .wide: "Wide"
        }
    }

    var symbol: String {
        switch self {
        case .small: "square"
        case .medium: "rectangle"
        case .large: "rectangle.portrait"
        case .wide: "rectangle.split.3x1"
        }
    }

    func size(for kind: LayerKind) -> CGSize {
        if kind == .video || kind == .youtube || kind == .image || kind == .photoAlbum || kind == .webSnapshot || kind == .windowCapture {
            switch self {
            case .small: return CGSize(width: 320, height: 180)
            case .medium: return CGSize(width: 480, height: 270)
            case .large: return CGSize(width: 640, height: 360)
            case .wide: return CGSize(width: 768, height: 432)
            }
        }
        if kind == .text {
            switch self {
            case .small: return CGSize(width: 300, height: 120)
            case .medium: return CGSize(width: 500, height: 160)
            case .large: return CGSize(width: 560, height: 340)
            case .wide: return CGSize(width: 760, height: 150)
            }
        }
        switch self {
        case .small: return CGSize(width: 300, height: 180)
        case .medium: return CGSize(width: 460, height: 230)
        case .large: return CGSize(width: 560, height: 370)
        case .wide: return CGSize(width: 720, height: 210)
        }
    }
}

enum WidgetCategory: String, CaseIterable, Identifiable {
    case essentials = "Essentials"
    case media = "Media"
    case productivity = "Productivity"
    case system = "Mac & System"
    case information = "Information"
    case connected = "Connected Services"

    var id: String { rawValue }
}

enum LayerKind: String, Codable, CaseIterable, Identifiable {
    case clock, weather, codex, image, video, text, shape
    case nowPlaying, lyrics, notification, calendar, reminders, focusTimer
    case systemMonitor, networkSpeed, airPods, youtube
    case rss, finance, sports, transit, worldClock, github, smartHome
    case chatStatus, creatorCounter, audioVisualizer, photoAlbum, webSnapshot
    case packageTracker, environment, messageBoard, screenTime
    case temperature, fps, windowCapture
    case powerSupply

    var id: String { rawValue }

    var title: String {
        switch self {
        case .clock: "Clock"
        case .weather: "Weather"
        case .codex: "Codex Usage"
        case .image: "Image"
        case .video: "Video"
        case .text: "Text"
        case .shape: "Shape"
        case .nowPlaying: "Now Playing"
        case .lyrics: "Lyrics"
        case .notification: "Notification"
        case .calendar: "Calendar"
        case .reminders: "Reminders"
        case .focusTimer: "Focus Timer"
        case .systemMonitor: "System Monitor"
        case .networkSpeed: "Network Speed"
        case .airPods: "AirPods"
        case .youtube: "YouTube"
        case .rss: "RSS Headlines"
        case .finance: "Stocks & Crypto"
        case .sports: "Sports"
        case .transit: "Transit"
        case .worldClock: "World Clocks"
        case .github: "GitHub"
        case .smartHome: "Smart Home"
        case .chatStatus: "Chat Status"
        case .creatorCounter: "Creator Counter"
        case .audioVisualizer: "Audio Visualizer"
        case .photoAlbum: "Photo Album"
        case .webSnapshot: "Web Snapshot"
        case .packageTracker: "Package Tracker"
        case .environment: "Environment"
        case .messageBoard: "Message Board"
        case .screenTime: "Screen Time"
        case .temperature: "CPU & GPU Temperature"
        case .fps: "FPS"
        case .windowCapture: "Window Capture"
        case .powerSupply: "Power Supply"
        }
    }

    var symbol: String {
        switch self {
        case .clock: "clock.fill"
        case .weather: "cloud.sun.fill"
        case .codex: "sparkles"
        case .image: "photo.fill"
        case .video: "play.rectangle.fill"
        case .text: "textformat"
        case .shape: "square.fill"
        case .nowPlaying: "music.note"
        case .lyrics: "quote.bubble.fill"
        case .notification: "bell.badge.fill"
        case .calendar: "calendar"
        case .reminders: "checklist"
        case .focusTimer: "timer"
        case .systemMonitor: "gauge.with.dots.needle.67percent"
        case .networkSpeed: "arrow.up.arrow.down"
        case .airPods: "airpodspro"
        case .youtube: "play.tv.fill"
        case .rss: "dot.radiowaves.left.and.right"
        case .finance: "chart.line.uptrend.xyaxis"
        case .sports: "sportscourt.fill"
        case .transit: "tram.fill"
        case .worldClock: "globe"
        case .github: "chevron.left.forwardslash.chevron.right"
        case .smartHome: "house.fill"
        case .chatStatus: "bubble.left.and.bubble.right.fill"
        case .creatorCounter: "person.2.fill"
        case .audioVisualizer: "waveform"
        case .photoAlbum: "photo.stack.fill"
        case .webSnapshot: "safari.fill"
        case .packageTracker: "shippingbox.fill"
        case .environment: "leaf.fill"
        case .messageBoard: "text.bubble.fill"
        case .screenTime: "hourglass.circle.fill"
        case .temperature: "thermometer.medium"
        case .fps: "speedometer"
        case .windowCapture: "macwindow.on.rectangle"
        case .powerSupply: "bolt.horizontal.circle.fill"
        }
    }

    var category: WidgetCategory {
        switch self {
        case .clock, .weather, .text, .shape, .image, .video:
            .essentials
        case .nowPlaying, .lyrics, .youtube, .audioVisualizer, .photoAlbum:
            .media
        case .calendar, .reminders, .focusTimer, .worldClock, .messageBoard, .screenTime:
            .productivity
        case .systemMonitor, .networkSpeed, .airPods, .codex, .temperature, .fps, .windowCapture, .powerSupply:
            .system
        case .notification, .rss, .finance, .sports, .transit, .packageTracker, .environment:
            .information
        case .github, .smartHome, .chatStatus, .creatorCounter, .webSnapshot:
            .connected
        }
    }

    var summary: String {
        switch self {
        case .clock: "Local date and time"
        case .weather: "Current conditions and forecast"
        case .codex: "Usage, reset and task status"
        case .image: "A photo from your Mac"
        case .video: "Loop a local video"
        case .text: "Custom text with font controls"
        case .shape: "Background and layout shape"
        case .nowPlaying: "Apple Music, Spotify or YouTube Music"
        case .lyrics: "Automatic synced lyrics"
        case .notification: "Private banners and alerts"
        case .calendar: "Next event and meeting countdown"
        case .reminders: "Tasks and due items"
        case .focusTimer: "Pomodoro, timer or stopwatch"
        case .systemMonitor: "Live CPU, RAM and GPU usage"
        case .networkSpeed: "Live upload and download speed"
        case .airPods: "Connection status and animation"
        case .youtube: "Play a YouTube or YouTube Music video"
        case .rss: "Rotating feed headlines"
        case .finance: "Stocks, currencies and crypto"
        case .sports: "Scores and upcoming games"
        case .transit: "Departures, delays and commute"
        case .worldClock: "Time across several cities"
        case .github: "Pull requests, commits and builds"
        case .smartHome: "Home Assistant and accessories"
        case .chatStatus: "Slack, Teams or Discord status"
        case .creatorCounter: "YouTube and Twitch milestones"
        case .audioVisualizer: "Live microphone audio bars"
        case .photoAlbum: "Rotating photo collection"
        case .webSnapshot: "A refreshed webpage or dashboard"
        case .packageTracker: "Delivery status and arrival"
        case .environment: "AQI, UV, pollen, moon and tides"
        case .messageBoard: "Message, status or QR card"
        case .screenTime: "Today’s foreground app activity"
        case .temperature: "Live CPU and GPU die temperature"
        case .fps: "Actual and target output frame rate"
        case .windowCapture: "Show a chosen Mac window"
        case .powerSupply: "Live darkFlash VD1200P rails, fan and AC input"
        }
    }

    var worksLocally: Bool {
        switch self {
        case .clock, .weather, .codex, .image, .video, .text, .shape, .nowPlaying, .lyrics,
             .focusTimer, .systemMonitor, .networkSpeed, .airPods, .youtube,
             .rss, .worldClock, .audioVisualizer, .photoAlbum, .messageBoard, .environment, .screenTime,
             .temperature, .fps, .windowCapture, .powerSupply:
            true
        default:
            false
        }
    }
}

struct StudioFrame: Codable, Equatable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    var rect: CGRect {
        get { CGRect(x: x, y: y, width: width, height: height) }
        set {
            x = newValue.origin.x
            y = newValue.origin.y
            width = newValue.size.width
            height = newValue.size.height
        }
    }
}

struct StudioLayer: Codable, Identifiable, Equatable {
    var id = UUID()
    var kind: LayerKind
    var name: String
    var frame: StudioFrame
    var opacity: Double = 1
    var cornerRadius: Double = 32
    var foregroundHex = "#FFFFFF"
    var backgroundHex = "#171922"
    var text = "Your text"
    var assetPath: String?
    var isHidden = false
    var isLocked = false
    var fontSize: Double = 54
    var latitude: Double = 31.2304
    var longitude: Double = 121.4737
    var locationName = "Shanghai"
    var weatherTemperature: Double?
    var weatherCode = 0
    var weatherIsDay = true
    var codexUsedPercent: Double = 36
    var codexResetLabel = "Resets in 2h 18m"
    var fontName: String?
    var config: [String: String]?
    var numericConfig: [String: Double]?

    func configValue(_ key: String, fallback: String = "") -> String {
        config?[key] ?? fallback
    }

    func numberValue(_ key: String, fallback: Double = 0) -> Double {
        numericConfig?[key] ?? fallback
    }

    var sizePreset: WidgetSizePreset? {
        WidgetSizePreset(rawValue: configValue("sizePreset"))
    }

    func contentScale(for frame: CGRect) -> Double {
        let designWidth = max(1, numberValue("designWidth", fallback: self.frame.width))
        let designHeight = max(1, numberValue("designHeight", fallback: self.frame.height))
        return max(0.35, min(frame.width / designWidth, frame.height / designHeight))
    }
}

struct StudioScene: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var backgroundHex = "#090A0F"
    var layers: [StudioLayer]
    var automaticallyMatchArtwork: Bool? = nil
    /// Optional keeps projects made before multi-display support fully compatible.
    var outputDisplay: StudioDisplayProfile? = nil
    /// Rotation describes how the physical panel is mounted. The editor stays
    /// upright while live output is rotated to match the mounted screen.
    var outputRotation: StudioDisplayRotation? = nil

    var resolvedOutputDisplay: StudioDisplayProfile { outputDisplay ?? .d92 }
    var resolvedOutputRotation: StudioDisplayRotation { outputRotation ?? .degrees0 }
    var canvasSize: CGSize {
        let physical = resolvedOutputDisplay.canvasSize
        guard resolvedOutputRotation.swapsCanvasAxes else { return physical }
        return CGSize(width: physical.height, height: physical.width)
    }
}

struct StudioProject: Codable, Equatable {
    var name = "My Project"
    var scenes: [StudioScene]

    static let starter = StudioProject(scenes: [
        StudioScene(name: "Daily Focus", layers: [
            StudioLayer(
                kind: .clock,
                name: "Local Time",
                frame: StudioFrame(x: 48, y: 44, width: 600, height: 374),
                cornerRadius: 42
            ),
            StudioLayer(
                kind: .weather,
                name: "Weather",
                frame: StudioFrame(x: 672, y: 44, width: 534, height: 374),
                cornerRadius: 42
            ),
            StudioLayer(
                kind: .codex,
                name: "Codex Usage",
                frame: StudioFrame(x: 1230, y: 44, width: 642, height: 374),
                cornerRadius: 42
            )
        ]),
        StudioScene(name: "Media", backgroundHex: "#06070A", layers: [
            StudioLayer(
                kind: .text,
                name: "Drop media here",
                frame: StudioFrame(x: 420, y: 122, width: 1080, height: 220),
                text: "Drop a photo or video onto the canvas",
                fontSize: 52
            )
        ])
    ])
}

extension Color {
    init(studioHex hex: String) {
        var clean = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        clean = clean.replacingOccurrences(of: "#", with: "")
        var value: UInt64 = 0
        Scanner(string: clean).scanHexInt64(&value)
        let r, g, b: Double
        if clean.count == 6 {
            r = Double((value >> 16) & 0xff) / 255
            g = Double((value >> 8) & 0xff) / 255
            b = Double(value & 0xff) / 255
        } else {
            r = 0.08; g = 0.09; b = 0.12
        }
        self.init(red: r, green: g, blue: b)
    }
}

extension NSColor {
    convenience init?(studioHex hex: String) {
        let clean = hex.replacingOccurrences(of: "#", with: "")
        guard clean.count == 6, let value = Int(clean, radix: 16) else { return nil }
        self.init(
            red: CGFloat((value >> 16) & 0xff) / 255,
            green: CGFloat((value >> 8) & 0xff) / 255,
            blue: CGFloat(value & 0xff) / 255,
            alpha: 1
        )
    }
}
