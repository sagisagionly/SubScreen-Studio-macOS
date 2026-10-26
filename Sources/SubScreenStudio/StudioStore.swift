import AppKit
import Combine
import Foundation
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class StudioStore: ObservableObject {
    @Published var project: StudioProject
    @Published var selectedSceneID: UUID?
    @Published var selectedLayerID: UUID?
    @Published var inspectorTab = 0
    @Published var showGrid = true
    @Published var snapToGrid = true
    /// OBS-style behavior: corner handles preserve aspect ratio by default;
    /// side handles always stretch. Holding Shift temporarily frees a corner.
    @Published var preserveAspectRatio = true
    @Published var verticalSnapGuides: [CGFloat] = []
    @Published var horizontalSnapGuides: [CGFloat] = []
    @Published private(set) var liveDisplays: Set<StudioDisplayProfile> = []
    @Published private(set) var displayStatuses: [StudioDisplayProfile: String] = [
        .d92: "Ready",
        .dq288: "Ready"
    ]
    @Published var connectionText = "Preview"
    @Published var youtubeSessionStatus = YouTubeMediaResolver.hasPersistentSession ? "Browser session saved" : ""
    @Published var zoom: Double = 0.46
    @Published var fitPreview = true
    @Published var effectivePreviewScale: Double = 0.46
    @Published var outputFPS: Double = {
        let saved = UserDefaults.standard.double(forKey: "outputFPS")
        return saved > 0 ? min(max(saved, 1), 60) : 30
    }() {
        didSet {
            UserDefaults.standard.set(min(max(outputFPS, 1), 60), forKey: "outputFPS")
            if isLive { restartLiveOutputs() }
        }
    }
    @Published var autoRotateScenes: Bool = UserDefaults.standard.bool(forKey: "autoRotateScenes") {
        didSet {
            UserDefaults.standard.set(autoRotateScenes, forKey: "autoRotateScenes")
            configureSceneRotation()
        }
    }
    @Published var sceneRotationSeconds: Double = max(10, UserDefaults.standard.double(forKey: "sceneRotationSeconds")) {
        didSet {
            UserDefaults.standard.set(sceneRotationSeconds, forKey: "sceneRotationSeconds")
            configureSceneRotation()
        }
    }

    private let saveURL: URL
    private var streamers: [StudioDisplayProfile: SSPStreamer] = [
        .d92: SSPStreamer(),
        .dq288: SSPStreamer()
    ]
    private var streamTimers: [StudioDisplayProfile: Timer] = [:]
    private var liveSceneIDs: [StudioDisplayProfile: UUID] = [:]
    private var brightnessTasks: [StudioDisplayProfile: DispatchWorkItem] = [:]
    private var sceneRotationTimer: Timer?
    private var cancellables = Set<AnyCancellable>()
    private var layerInteractionDepth = 0
    private var rendersInFlight: Set<StudioDisplayProfile> = []
    @Published private(set) var brightnessValues: [StudioDisplayProfile: Int] = [
        .d92: StudioStore.savedBrightness(for: .d92),
        .dq288: StudioStore.savedBrightness(for: .dq288)
    ]

    var isLive: Bool { !liveDisplays.isEmpty }

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let folder = support.appendingPathComponent("SubScreenStudio", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        saveURL = folder.appendingPathComponent("studio.json")
        if let data = try? Data(contentsOf: saveURL),
           let saved = try? JSONDecoder().decode(StudioProject.self, from: data) {
            project = saved
        } else {
            project = .starter
        }
        if project.name == "D92 Studio" { project.name = "My Project" }
        migrateLayerDesignSizesAndVideoRatios()
        installPresetScenesIfNeeded()
        selectedSceneID = project.scenes.first?.id
        AirPodsMonitor.shared.$connectionSequence
            .dropFirst()
            .filter { $0 > 0 }
            .sink { [weak self] _ in
                guard let name = AirPodsMonitor.shared.connectedName else { return }
                self?.notifyLiveDisplays(title: "AirPods Connected", detail: name)
            }
            .store(in: &cancellables)
        IPhoneConnectionMonitor.shared.$connectionSequence
            .dropFirst()
            .filter { $0 > 0 }
            .sink { [weak self] _ in
                guard let name = IPhoneConnectionMonitor.shared.connectedName else { return }
                self?.notifyLiveDisplays(title: "iPhone Connected", detail: name)
            }
            .store(in: &cancellables)
        NowPlayingMonitor.shared.$artwork
            .compactMap { $0 }
            .sink { [weak self] artwork in self?.applyArtworkBackground(artwork) }
            .store(in: &cancellables)
        configureSceneRotation()
        Task { await refreshWeather() }
    }

    var sceneIndex: Int? {
        guard let id = selectedSceneID else { return nil }
        return project.scenes.firstIndex { $0.id == id }
    }

    var currentScene: StudioScene? {
        guard let index = sceneIndex else { return nil }
        return project.scenes[index]
    }

    var canvasSize: CGSize { currentScene?.canvasSize ?? studioCanvasSize }

    var currentDisplayProfile: StudioDisplayProfile {
        currentScene?.resolvedOutputDisplay ?? .d92
    }

    var selectedLayer: StudioLayer? {
        guard let scene = currentScene, let id = selectedLayerID else { return nil }
        return scene.layers.first { $0.id == id }
    }

    func selectScene(_ id: UUID) {
        selectedSceneID = id
        selectedLayerID = nil
        inspectorTab = 0
        guard let scene = currentScene else { return }
        let profile = scene.resolvedOutputDisplay
        if isDisplayLive(profile) {
            liveSceneIDs[profile] = scene.id
            reconnectLiveOutput(profile)
        }
    }

    func addScene() {
        let scene = StudioScene(
            name: "Scene \(project.scenes.count + 1)",
            layers: [],
            outputDisplay: currentScene?.resolvedOutputDisplay ?? .d92,
            outputRotation: currentScene?.resolvedOutputRotation ?? .degrees0
        )
        project.scenes.append(scene)
        selectedSceneID = scene.id
        selectedLayerID = nil
        save()
    }

    func duplicateCurrentScene() {
        guard var scene = currentScene else { return }
        scene.id = UUID()
        scene.name += " Copy"
        scene.layers = scene.layers.map { item in
            var copy = item
            copy.id = UUID()
            return copy
        }
        project.scenes.append(scene)
        selectedSceneID = scene.id
        save()
    }

    func deleteCurrentScene() {
        guard project.scenes.count > 1, let index = sceneIndex else { return }
        let deleted = project.scenes[index]
        if liveSceneIDs[deleted.resolvedOutputDisplay] == deleted.id {
            stopLive(deleted.resolvedOutputDisplay)
        }
        project.scenes.remove(at: index)
        selectedSceneID = project.scenes[min(index, project.scenes.count - 1)].id
        selectedLayerID = nil
        save()
    }

    func setSceneDisplayProfile(_ profile: StudioDisplayProfile) {
        guard let sceneIndex else { return }
        let sceneID = project.scenes[sceneIndex].id
        let oldProfile = project.scenes[sceneIndex].resolvedOutputDisplay
        let oldSize = project.scenes[sceneIndex].canvasSize
        guard oldProfile != profile else { return }
        let rotation = project.scenes[sceneIndex].resolvedOutputRotation
        let physical = profile.canvasSize
        let newSize = rotation.swapsCanvasAxes
            ? CGSize(width: physical.height, height: physical.width)
            : physical
        let scaleX = newSize.width / oldSize.width
        let scaleY = newSize.height / oldSize.height
        for layerIndex in project.scenes[sceneIndex].layers.indices {
            var frame = project.scenes[sceneIndex].layers[layerIndex].frame
            frame.x *= scaleX
            frame.y *= scaleY
            frame.width *= scaleX
            frame.height *= scaleY
            project.scenes[sceneIndex].layers[layerIndex].frame = frame
        }
        project.scenes[sceneIndex].outputDisplay = profile
        save()
        if liveSceneIDs[oldProfile] == sceneID {
            stopLive(oldProfile)
            startLive(profile, sceneID: sceneID)
        }
    }

    func setSceneRotation(_ rotation: StudioDisplayRotation) {
        guard let sceneIndex else { return }
        let sceneID = project.scenes[sceneIndex].id
        let oldSize = project.scenes[sceneIndex].canvasSize
        guard project.scenes[sceneIndex].resolvedOutputRotation != rotation else { return }
        let physical = project.scenes[sceneIndex].resolvedOutputDisplay.canvasSize
        let newSize = rotation.swapsCanvasAxes
            ? CGSize(width: physical.height, height: physical.width)
            : physical
        let scaleX = newSize.width / oldSize.width
        let scaleY = newSize.height / oldSize.height
        for layerIndex in project.scenes[sceneIndex].layers.indices {
            var frame = project.scenes[sceneIndex].layers[layerIndex].frame
            frame.x *= scaleX
            frame.y *= scaleY
            frame.width *= scaleX
            frame.height *= scaleY
            project.scenes[sceneIndex].layers[layerIndex].frame = frame
        }
        project.scenes[sceneIndex].outputRotation = rotation
        save()
        let profile = project.scenes[sceneIndex].resolvedOutputDisplay
        if liveSceneIDs[profile] == sceneID { reconnectLiveOutput(profile) }
    }

    private func configureSceneRotation() {
        sceneRotationTimer?.invalidate()
        sceneRotationTimer = nil
        guard autoRotateScenes else { return }
        sceneRotationTimer = Timer.scheduledTimer(withTimeInterval: max(10, sceneRotationSeconds), repeats: true) { [weak self] _ in
            Task { @MainActor in self?.advanceScene() }
        }
    }

    private func advanceScene() {
        guard project.scenes.count > 1,
              let current = sceneIndex else { return }
        selectedSceneID = project.scenes[(current + 1) % project.scenes.count].id
        selectedLayerID = nil
        if let scene = currentScene, isDisplayLive(scene.resolvedOutputDisplay) {
            liveSceneIDs[scene.resolvedOutputDisplay] = scene.id
            reconnectLiveOutput(scene.resolvedOutputDisplay)
        }
    }

    func addLayer(_ kind: LayerKind, at point: CGPoint? = nil, assetURL: URL? = nil, preset: WidgetSizePreset = .medium) {
        guard let sceneIndex else { return }
        let size = fittedPresetSize(preset, for: kind)
        let origin = CGPoint(
            x: min(max(0, (point?.x ?? canvasSize.width / 2) - size.width / 2), canvasSize.width - size.width),
            y: min(max(0, (point?.y ?? canvasSize.height / 2) - size.height / 2), canvasSize.height - size.height)
        )
        var layer = StudioLayer(
            kind: kind,
            name: assetURL?.deletingPathExtension().lastPathComponent ?? kind.title,
            frame: StudioFrame(x: origin.x, y: origin.y, width: size.width, height: size.height)
        )
        layer.assetPath = assetURL?.path
        if kind == .image || kind == .video || kind == .youtube || kind == .photoAlbum || kind == .webSnapshot {
            layer.cornerRadius = 22
        }
        applyDefaults(to: &layer)
        var config = layer.config ?? [:]
        config["sizePreset"] = preset.rawValue
        layer.config = config
        var metrics = layer.numericConfig ?? [:]
        metrics["designWidth"] = size.width
        metrics["designHeight"] = size.height
        layer.numericConfig = metrics
        project.scenes[sceneIndex].layers.append(layer)
        selectedLayerID = layer.id
        inspectorTab = 1
        save()
    }

    private func applyDefaults(to layer: inout StudioLayer) {
        switch layer.kind {
        case .nowPlaying:
            layer.text = "Nothing playing"
            layer.config = ["subtitle": "Apple Music, Spotify or YouTube Music"]
        case .lyrics:
            layer.text = "Lyrics appear automatically"
            layer.fontSize = 64
            layer.config = ["subtitle": "Automatic multi-source lyrics"]
        case .notification:
            layer.text = "Notifications"
            layer.config = ["subtitle": "New alerts appear here"]
        case .calendar:
            layer.text = "Next event"
            layer.config = ["subtitle": "Connect Calendar in Settings", "value": "10:00"]
        case .reminders:
            layer.text = "Today"
            layer.config = ["subtitle": "Connect Reminders in Settings", "value": "3 tasks"]
        case .focusTimer:
            layer.text = "Focus"
            layer.config = ["subtitle": "Ready", "value": "25:00"]
            layer.numericConfig = ["minutes": 25]
        case .systemMonitor:
            layer.text = "Mac Performance"
        case .networkSpeed:
            layer.text = "Network"
        case .airPods:
            layer.text = "AirPods"
            layer.config = ["subtitle": "Waiting for connection"]
        case .youtube:
            layer.text = "YouTube"
            layer.config = ["url": "https://www.youtube.com/watch?v=M7lc1UVf-VE", "cookiesBrowser": "auto"]
        case .rss:
            layer.text = "Tech News"
            layer.config = ["subtitle": "Latest headlines", "source": "TechCrunch", "url": "https://techcrunch.com/feed/"]
        case .finance:
            layer.text = "AAPL"
            layer.config = ["subtitle": "Market closed", "value": "$—"]
        case .sports:
            layer.text = "Live scores"
            layer.config = ["subtitle": "Choose a team or league", "value": "—"]
        case .transit:
            layer.text = "Next departure"
            layer.config = ["subtitle": "Add a station", "value": "— min"]
        case .worldClock:
            layer.text = "World Clocks"
            layer.config = [
                "clockCity1": "Shanghai", "clockZone1": "Asia/Shanghai",
                "clockCity2": "London", "clockZone2": "Europe/London",
                "clockCity3": "New York", "clockZone3": "America/New_York"
            ]
        case .github:
            layer.text = "GitHub"
            layer.config = ["subtitle": "Connect an account", "value": "Build —"]
        case .smartHome:
            layer.text = "Home"
            layer.config = ["subtitle": "Connect Home Assistant", "value": "All good"]
        case .chatStatus:
            layer.text = "Messages"
            layer.config = ["subtitle": "Connect Slack, Teams or Discord", "value": "0"]
        case .creatorCounter:
            layer.text = "Audience"
            layer.config = ["subtitle": "YouTube or Twitch", "value": "—"]
        case .audioVisualizer:
            layer.text = "Audio"
        case .photoAlbum:
            layer.text = "Photo Album"
            layer.config = ["subtitle": "Choose an image folder"]
        case .webSnapshot:
            layer.text = "Web Snapshot"
            layer.config = ["url": "https://example.com", "subtitle": "Add a dashboard URL"]
        case .packageTracker:
            layer.text = "Package"
            layer.config = ["subtitle": "Add a tracking number", "value": "In transit"]
        case .environment:
            layer.text = "Environment"
            layer.config = ["subtitle": "Current location", "value": "Locating…"]
        case .screenTime:
            layer.text = "Today"
            layer.config = ["subtitle": "Foreground app activity"]
        case .temperature:
            layer.text = "Thermals"
        case .fps:
            layer.text = "Output FPS"
        case .powerSupply:
            layer.text = "VD1200P"
            layer.config = [
                "rail12ALabel": "12V Channel A",
                "rail12BLabel": "12V Channel B"
            ]
        case .windowCapture:
            layer.text = "Window Capture"
            layer.config = ["windowID": ""]
        case .messageBoard:
            layer.text = "Welcome"
            layer.config = ["subtitle": "Edit this message"]
        default:
            break
        }
    }

    func importFiles(_ urls: [URL], at point: CGPoint) {
        var offset = CGPoint.zero
        for url in urls {
            let ext = url.pathExtension.lowercased()
            let videos = ["mp4", "mov", "m4v", "webm"]
            let images = ["png", "jpg", "jpeg", "gif", "heic", "tiff", "webp"]
            if videos.contains(ext) {
                addLayer(.video, at: CGPoint(x: point.x + offset.x, y: point.y + offset.y), assetURL: url)
            } else if images.contains(ext) {
                addLayer(.image, at: CGPoint(x: point.x + offset.x, y: point.y + offset.y), assetURL: url)
            }
            offset.x += 24
            offset.y += 18
        }
    }

    func chooseMediaFiles(replacingSelection: Bool = false) {
        let panel = NSOpenPanel()
        panel.title = replacingSelection ? "Replace Media" : "Import Media"
        panel.prompt = replacingSelection ? "Replace" : "Import"
        panel.allowedContentTypes = [.image, .movie]
        panel.allowsMultipleSelection = !replacingSelection
        panel.canChooseDirectories = false

        guard panel.runModal() == .OK else { return }
        if replacingSelection,
           let url = panel.urls.first,
           let id = selectedLayerID,
           let kind = selectedLayer?.kind,
           kind == .image || kind == .video {
            let newKind: LayerKind = Self.videoExtensions.contains(url.pathExtension.lowercased()) ? .video : .image
            updateLayer(id) {
                $0.kind = newKind
                $0.assetPath = url.path
                $0.name = url.deletingPathExtension().lastPathComponent
            }
        } else {
            importFiles(panel.urls, at: CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2))
        }
    }

    func revealSelectedMedia() {
        guard let path = selectedLayer?.assetPath,
              FileManager.default.fileExists(atPath: path) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    var selectedMediaExists: Bool {
        guard let path = selectedLayer?.assetPath else { return false }
        return FileManager.default.fileExists(atPath: path)
    }

    func updateLayer(_ id: UUID, persist: Bool = true, _ change: (inout StudioLayer) -> Void) {
        guard let sceneIndex,
              let layerIndex = project.scenes[sceneIndex].layers.firstIndex(where: { $0.id == id }) else { return }
        change(&project.scenes[sceneIndex].layers[layerIndex])
        if persist { save() }
        if isLive { prepareLiveVideoFrames() }
    }

    func layer(withID id: UUID) -> StudioLayer? {
        currentScene?.layers.first { $0.id == id }
    }

    func selectLayer(_ id: UUID) {
        selectedLayerID = id
        inspectorTab = 1
    }

    func moveLayer(_ id: UUID, to frame: CGRect, snap: Bool = false, persist: Bool = false) {
        let adjusted = previewMoveFrame(frame, excluding: id, snap: snap)
        updateLayer(id, persist: persist) { $0.frame.rect = adjusted }
    }

    func transformLayer(_ id: UUID, to proposed: CGRect, snap: Bool = true, persist: Bool = false) {
        let frame = previewResizeFrame(proposed, excluding: id, snap: snap)
        updateLayer(id, persist: persist) { $0.frame.rect = frame }
    }

    func previewMoveFrame(_ proposed: CGRect, excluding id: UUID, snap: Bool = true) -> CGRect {
        if !snap || !snapToGrid { clearSnapGuides() }
        var frame = snap && snapToGrid ? snappedFrame(proposed, excluding: id) : proposed
        frame.origin.x = min(max(0, frame.origin.x), canvasSize.width - frame.width)
        frame.origin.y = min(max(0, frame.origin.y), canvasSize.height - frame.height)
        return frame
    }

    func previewResizeFrame(_ proposed: CGRect, excluding id: UUID, snap: Bool = true) -> CGRect {
        if !snap || !snapToGrid { clearSnapGuides() }
        let original = layer(withID: id)?.frame.rect
        var frame = snap && snapToGrid ? snappedResizeFrame(proposed, excluding: id, original: original) : proposed
        frame.size.width = min(max(24, frame.width), canvasSize.width)
        frame.size.height = min(max(24, frame.height), canvasSize.height)
        frame.origin.x = min(max(0, frame.origin.x), canvasSize.width - frame.width)
        frame.origin.y = min(max(0, frame.origin.y), canvasSize.height - frame.height)
        return frame
    }

    func commitLayerFrame(_ id: UUID, frame: CGRect) {
        updateLayer(id, persist: true) { layer in
            layer.frame.rect = frame
            // Live transforms stay GPU-only. Once the pointer is released,
            // commit a new design size so responsive widgets reflow once and
            // remain pixel-identical in preview and on the physical display.
            var metrics = layer.numericConfig ?? [:]
            metrics["designWidth"] = frame.width
            metrics["designHeight"] = frame.height
            layer.numericConfig = metrics
            if let preset = layer.sizePreset {
                let size = preset.size(for: layer.kind)
                if abs(size.width - frame.width) > 1 || abs(size.height - frame.height) > 1 {
                    var config = layer.config ?? [:]
                    config.removeValue(forKey: "sizePreset")
                    layer.config = config
                }
            }
        }
        clearSnapGuides()
    }

    func applySizePreset(_ preset: WidgetSizePreset, to id: UUID? = nil) {
        guard let id = id ?? selectedLayerID, let layer = layer(withID: id) else { return }
        let size = fittedPresetSize(preset, for: layer.kind)
        var frame = layer.frame.rect
        let center = CGPoint(x: frame.midX, y: frame.midY)
        frame.size = size
        frame.origin = CGPoint(
            x: min(max(0, center.x - size.width / 2), canvasSize.width - size.width),
            y: min(max(0, center.y - size.height / 2), canvasSize.height - size.height)
        )
        updateLayer(id, persist: true) { item in
            item.frame.rect = frame
            var config = item.config ?? [:]
            config["sizePreset"] = preset.rawValue
            item.config = config
            var metrics = item.numericConfig ?? [:]
            metrics["designWidth"] = size.width
            metrics["designHeight"] = size.height
            item.numericConfig = metrics
        }
    }

    private func fittedPresetSize(_ preset: WidgetSizePreset, for kind: LayerKind) -> CGSize {
        let requested = preset.size(for: kind)
        let available = CGSize(width: max(24, canvasSize.width - 24), height: max(24, canvasSize.height - 24))
        let factor = min(1, available.width / requested.width, available.height / requested.height)
        return CGSize(width: requested.width * factor, height: requested.height * factor)
    }

    func beginLayerInteraction() {
        layerInteractionDepth += 1
        NowPlayingMonitor.shared.setEditorInteraction(active: true)
        // Publishing guide changes on every pointer event invalidated every
        // widget in the scene. Magnetic snapping remains active, but the live
        // compositor and unrelated widgets now stay completely still.
        clearSnapGuides()
    }

    func endLayerInteraction() {
        layerInteractionDepth = max(0, layerInteractionDepth - 1)
        NowPlayingMonitor.shared.setEditorInteraction(active: false)
        if layerInteractionDepth == 0,
           let scene = currentScene,
           liveSceneIDs[scene.resolvedOutputDisplay] == scene.id {
            renderAndSend(scene.resolvedOutputDisplay)
        }
    }

    func resizeLayer(_ id: UUID, to size: CGSize, persist: Bool = false) {
        guard var frame = layer(withID: id)?.frame.rect else { return }
        frame.size = size
        transformLayer(id, to: frame, snap: false, persist: persist)
    }

    func finishLayerInteraction(_ id: UUID) {
        guard let layer = layer(withID: id) else { return }
        moveLayer(id, to: layer.frame.rect, snap: true, persist: true)
        clearSnapGuides()
    }

    func clearSnapGuides() {
        if !verticalSnapGuides.isEmpty { verticalSnapGuides = [] }
        if !horizontalSnapGuides.isEmpty { horizontalSnapGuides = [] }
    }

    func nudgeSelected(dx: CGFloat, dy: CGFloat) {
        guard let id = selectedLayerID,
              let layer = layer(withID: id), !layer.isLocked else { return }
        var frame = layer.frame.rect
        frame.origin.x += dx
        frame.origin.y += dy
        moveLayer(id, to: frame, snap: false, persist: true)
    }

    func alignSelected(horizontal: HorizontalAlignmentChoice? = nil, vertical: VerticalAlignmentChoice? = nil) {
        guard let id = selectedLayerID, var frame = layer(withID: id)?.frame.rect else { return }
        if let horizontal {
            switch horizontal {
            case .left: frame.origin.x = 0
            case .center: frame.origin.x = (canvasSize.width - frame.width) / 2
            case .right: frame.origin.x = canvasSize.width - frame.width
            }
        }
        if let vertical {
            switch vertical {
            case .top: frame.origin.y = 0
            case .middle: frame.origin.y = (canvasSize.height - frame.height) / 2
            case .bottom: frame.origin.y = canvasSize.height - frame.height
            }
        }
        moveLayer(id, to: frame, persist: true)
    }

    private func snappedFrame(_ frame: CGRect, excluding id: UUID) -> CGRect {
        var result = frame
        let tolerance: CGFloat = 14
        let otherFrames = currentScene?.layers.filter { $0.id != id && !$0.isHidden }.map { $0.frame.rect } ?? []
        let xTargets: [CGFloat] = [0, canvasSize.width / 2, canvasSize.width] + otherFrames.reduce(into: []) { $0.append(contentsOf: [$1.minX, $1.midX, $1.maxX]) }
        let yTargets: [CGFloat] = [0, canvasSize.height / 2, canvasSize.height] + otherFrames.reduce(into: []) { $0.append(contentsOf: [$1.minY, $1.midY, $1.maxY]) }
        let xPoints: [(value: CGFloat, offset: CGFloat)] = [(frame.minX, 0), (frame.midX, frame.width / 2), (frame.maxX, frame.width)]
        let yPoints: [(value: CGFloat, offset: CGFloat)] = [(frame.minY, 0), (frame.midY, frame.height / 2), (frame.maxY, frame.height)]
        if let match = closestSnap(points: xPoints, targets: xTargets, tolerance: tolerance) {
            result.origin.x = match.target - match.offset
        }
        if let match = closestSnap(points: yPoints, targets: yTargets, tolerance: tolerance) {
            result.origin.y = match.target - match.offset
        }
        return result
    }

    private func snappedResizeFrame(_ frame: CGRect, excluding id: UUID, original: CGRect?) -> CGRect {
        var result = frame
        let tolerance: CGFloat = 14
        let others = currentScene?.layers.filter { $0.id != id && !$0.isHidden }.map { $0.frame.rect } ?? []
        let xTargets: [CGFloat] = [0, canvasSize.width / 2, canvasSize.width] + others.reduce(into: []) { $0.append(contentsOf: [$1.minX, $1.midX, $1.maxX]) }
        let yTargets: [CGFloat] = [0, canvasSize.height / 2, canvasSize.height] + others.reduce(into: []) { $0.append(contentsOf: [$1.minY, $1.midY, $1.maxY]) }
        let movesLeft = original.map { abs(frame.minX - $0.minX) > 0.01 } ?? true
        let movesRight = original.map { abs(frame.maxX - $0.maxX) > 0.01 } ?? true
        let movesTop = original.map { abs(frame.minY - $0.minY) > 0.01 } ?? true
        let movesBottom = original.map { abs(frame.maxY - $0.maxY) > 0.01 } ?? true
        if movesLeft, let left = xTargets.min(by: { abs($0 - frame.minX) < abs($1 - frame.minX) }), abs(left - frame.minX) <= tolerance {
            let oldMax = result.maxX; result.origin.x = left; result.size.width = oldMax - left
        }
        if movesRight, let right = xTargets.min(by: { abs($0 - frame.maxX) < abs($1 - frame.maxX) }), abs(right - frame.maxX) <= tolerance {
            result.size.width = right - result.minX
        }
        if movesTop, let top = yTargets.min(by: { abs($0 - frame.minY) < abs($1 - frame.minY) }), abs(top - frame.minY) <= tolerance {
            let oldMax = result.maxY; result.origin.y = top; result.size.height = oldMax - top
        }
        if movesBottom, let bottom = yTargets.min(by: { abs($0 - frame.maxY) < abs($1 - frame.maxY) }), abs(bottom - frame.maxY) <= tolerance {
            result.size.height = bottom - result.minY
        }
        return result
    }

    private func closestSnap(points: [(value: CGFloat, offset: CGFloat)], targets: [CGFloat], tolerance: CGFloat) -> (target: CGFloat, offset: CGFloat)? {
        points.flatMap { point in targets.map { (target: $0, offset: point.offset, distance: abs($0 - point.value)) } }
            .filter { $0.distance <= tolerance }
            .min { $0.distance < $1.distance }
            .map { ($0.target, $0.offset) }
    }

    func toggleLayerVisibility(_ id: UUID) {
        updateLayer(id) { $0.isHidden.toggle() }
    }

    func toggleLayerLock(_ id: UUID) {
        updateLayer(id) { $0.isLocked.toggle() }
    }

    func deleteSelectedLayer() {
        guard let sceneIndex, let id = selectedLayerID else { return }
        project.scenes[sceneIndex].layers.removeAll { $0.id == id }
        selectedLayerID = nil
        save()
    }

    func moveLayerInStack(_ id: UUID, delta: Int) {
        guard let sceneIndex,
              let index = project.scenes[sceneIndex].layers.firstIndex(where: { $0.id == id }) else { return }
        let destination = min(max(0, index + delta), project.scenes[sceneIndex].layers.count - 1)
        guard destination != index else { return }
        let item = project.scenes[sceneIndex].layers.remove(at: index)
        project.scenes[sceneIndex].layers.insert(item, at: destination)
        save()
    }

    func layerBinding<Value>(_ keyPath: WritableKeyPath<StudioLayer, Value>, fallback: Value) -> Binding<Value> {
        Binding(
            get: { self.selectedLayer?[keyPath: keyPath] ?? fallback },
            set: { value in
                guard let id = self.selectedLayerID else { return }
                self.updateLayer(id) { $0[keyPath: keyPath] = value }
            }
        )
    }

    func sceneBinding<Value>(_ keyPath: WritableKeyPath<StudioScene, Value>, fallback: Value) -> Binding<Value> {
        Binding(
            get: { self.currentScene?[keyPath: keyPath] ?? fallback },
            set: { value in
                guard let sceneIndex = self.sceneIndex else { return }
                self.project.scenes[sceneIndex][keyPath: keyPath] = value
                self.save()
            }
        )
    }

    func configBinding(_ key: String, fallback: String = "") -> Binding<String> {
        Binding(
            get: { self.selectedLayer?.config?[key] ?? fallback },
            set: { value in
                guard let id = self.selectedLayerID else { return }
                self.updateLayer(id) { layer in
                    var values = layer.config ?? [:]
                    values[key] = value
                    layer.config = values
                }
            }
        )
    }

    func numberConfigBinding(_ key: String, fallback: Double = 0) -> Binding<Double> {
        Binding(
            get: { self.selectedLayer?.numericConfig?[key] ?? fallback },
            set: { value in
                guard let id = self.selectedLayerID else { return }
                self.updateLayer(id) { layer in
                    var values = layer.numericConfig ?? [:]
                    values[key] = value
                    layer.numericConfig = values
                }
            }
        )
    }

    func chooseLyricsFile() {
        let panel = NSOpenPanel()
        panel.title = "Choose Synced Lyrics"
        panel.prompt = "Choose"
        panel.allowedContentTypes = [UTType(filenameExtension: "lrc") ?? .plainText, .plainText]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url, let id = selectedLayerID else { return }
        updateLayer(id) {
            $0.assetPath = url.path
            if let contents = try? String(contentsOf: url, encoding: .utf8),
               let first = contents.split(separator: "\n").map(String.init).first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) {
                $0.text = first.replacingOccurrences(of: #"\[[0-9:.]+\]"#, with: "", options: .regularExpression)
            }
        }
    }

    func chooseYouTubeCookiesFile() {
        guard let id = selectedLayerID else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.plainText]
        panel.message = "Choose a Netscape-format cookies.txt exported from the browser where YouTube is signed in."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        updateLayer(id) { layer in
            var values = layer.config ?? [:]
            values["cookiesFile"] = url.path
            layer.config = values
        }
    }

    func saveSelectedYouTubeBrowserSession() {
        guard let layer = selectedLayer, layer.kind == .youtube else { return }
        let browser = layer.configValue("cookiesBrowser", fallback: "auto")
        guard browser != "none", let tools = YouTubeMediaResolver.tools else {
            youtubeSessionStatus = "Choose a signed-in browser and install YouTube support first"
            return
        }
        youtubeSessionStatus = browser == "auto" ? "Looking for a signed-in browser…" : "Connecting to \(browser.capitalized)…"
        Task {
            let result = await YouTubeMediaResolver.captureBrowserSession(
                browser: browser,
                input: layer.configValue("url"),
                tools: tools
            )
            switch result {
            case .success(let url):
                youtubeSessionStatus = "Connected • session saved on this Mac"
                if let id = selectedLayerID {
                    updateLayer(id) { item in
                        var config = item.config ?? [:]
                        config["cookiesFile"] = url.path
                        item.config = config
                    }
                }
            case .failure(let error):
                youtubeSessionStatus = error.localizedDescription
            }
        }
    }

    func setWeatherLocation(_ place: WeatherPlace) {
        guard let id = selectedLayerID else { return }
        updateLayer(id) {
            $0.locationName = place.displayName
            $0.latitude = place.latitude
            $0.longitude = place.longitude
        }
        Task { await refreshWeather() }
    }

    private func migrateLayerDesignSizesAndVideoRatios() {
        let normalizeVideo = !UserDefaults.standard.bool(forKey: "normalizedVideoAspectV1")
        let migrateYouTubeBrowser = !UserDefaults.standard.bool(forKey: "automaticYouTubeBrowserV1")
        var changed = false
        for sceneIndex in project.scenes.indices {
            let sceneSize = project.scenes[sceneIndex].canvasSize
            for layerIndex in project.scenes[sceneIndex].layers.indices {
                var layer = project.scenes[sceneIndex].layers[layerIndex]
                if normalizeVideo && (layer.kind == .video || layer.kind == .youtube) {
                    let targetWidth = min(layer.frame.width, sceneSize.height * 16 / 9)
                    let targetHeight = targetWidth * 9 / 16
                    layer.frame.width = targetWidth
                    layer.frame.height = targetHeight
                    layer.frame.x = min(layer.frame.x, sceneSize.width - targetWidth)
                    layer.frame.y = min(layer.frame.y, sceneSize.height - targetHeight)
                    changed = true
                }
                if migrateYouTubeBrowser && layer.kind == .youtube && layer.configValue("cookiesBrowser", fallback: "none") == "none" {
                    var config = layer.config ?? [:]
                    config["cookiesBrowser"] = "auto"
                    layer.config = config
                    changed = true
                }
                var values = layer.numericConfig ?? [:]
                if values["designWidth"] == nil { values["designWidth"] = layer.frame.width; changed = true }
                if values["designHeight"] == nil { values["designHeight"] = layer.frame.height; changed = true }
                layer.numericConfig = values
                project.scenes[sceneIndex].layers[layerIndex] = layer
            }
        }
        if normalizeVideo { UserDefaults.standard.set(true, forKey: "normalizedVideoAspectV1") }
        if migrateYouTubeBrowser { UserDefaults.standard.set(true, forKey: "automaticYouTubeBrowserV1") }
        if changed { save() }
    }

    private func installPresetScenesIfNeeded() {
        var presets: [StudioScene] = []
        if !UserDefaults.standard.bool(forKey: "installedBrandPresetScenesV1") {
            presets += [
            StudioScene(name: "Glass Drive", backgroundHex: "#050607", layers: [
                presetLayer(.clock, x: 42, y: 36, width: 490, height: 390, background: "#17181A"),
                presetLayer(.nowPlaying, x: 558, y: 36, width: 790, height: 390, background: "#18191C"),
                presetLayer(.screenTime, x: 1374, y: 36, width: 504, height: 390, background: "#15171A")
            ]),
            StudioScene(name: "Productivity Dashboard", backgroundHex: "#071A2B", layers: [
                presetLayer(.weather, x: 34, y: 32, width: 600, height: 398, background: "#0C5EA8"),
                presetLayer(.systemMonitor, x: 658, y: 32, width: 600, height: 190, background: "#1E293B"),
                presetLayer(.calendar, x: 658, y: 240, width: 600, height: 190, background: "#4338CA"),
                presetLayer(.codex, x: 1282, y: 32, width: 604, height: 398, background: "#111827")
            ]),
            StudioScene(name: "Material Drive", backgroundHex: "#101214", layers: [
                presetLayer(.clock, x: 30, y: 30, width: 480, height: 402, background: "#202124"),
                presetLayer(.nowPlaying, x: 534, y: 30, width: 820, height: 402, background: "#1F2327"),
                presetLayer(.weather, x: 1378, y: 30, width: 512, height: 402, background: "#174EA6")
            ]),
            StudioScene(name: "Electric Console", backgroundHex: "#090B0D", layers: [
                presetLayer(.environment, x: 28, y: 28, width: 540, height: 406, background: "#15191D"),
                presetLayer(.nowPlaying, x: 592, y: 28, width: 736, height: 406, background: "#121518"),
                presetLayer(.systemMonitor, x: 1352, y: 28, width: 540, height: 406, background: "#15191D")
            ])
            ]
            UserDefaults.standard.set(true, forKey: "installedBrandPresetScenesV1")
        }
        if !UserDefaults.standard.bool(forKey: "installedDQ288SceneV1") {
            presets.append(StudioScene(
                name: "2.88 Dashboard",
                backgroundHex: "#050608",
                layers: [
                    presetLayer(.clock, x: 12, y: 12, width: 456, height: 132, background: "#17191D", cornerRadius: 24),
                    presetLayer(.weather, x: 12, y: 156, width: 220, height: 148, background: "#16395C", cornerRadius: 22),
                    presetLayer(.networkSpeed, x: 12, y: 316, width: 220, height: 152, background: "#17191D", cornerRadius: 22),
                    presetLayer(.systemMonitor, x: 244, y: 156, width: 224, height: 312, background: "#17191D", cornerRadius: 22)
                ],
                outputDisplay: .dq288
            ))
            UserDefaults.standard.set(true, forKey: "installedDQ288SceneV1")
        }
        let existing = Set(project.scenes.map(\.name))
        project.scenes.append(contentsOf: presets.filter { !existing.contains($0.name) })
        if !presets.isEmpty { save() }
    }

    private func presetLayer(_ kind: LayerKind, x: Double, y: Double, width: Double, height: Double, background: String, cornerRadius: Double = 32) -> StudioLayer {
        var layer = StudioLayer(kind: kind, name: kind.title, frame: StudioFrame(x: x, y: y, width: width, height: height), cornerRadius: cornerRadius, backgroundHex: background)
        applyDefaults(to: &layer)
        var values = layer.numericConfig ?? [:]
        values["designWidth"] = width
        values["designHeight"] = height
        layer.numericConfig = values
        return layer
    }

    func startFocusTimer() {
        guard let id = selectedLayerID else { return }
        let minutes = selectedLayer?.numberValue("minutes", fallback: 25) ?? 25
        updateLayer(id) { layer in
            var values = layer.numericConfig ?? [:]
            values["endTime"] = Date().addingTimeInterval(minutes * 60).timeIntervalSince1970
            layer.numericConfig = values
        }
    }

    func playSelectedMediaOnDisplay() {
        guard let layer = selectedLayer else { return }
        let profile = currentDisplayProfile
        let displayName = profile.shortTitle
        guard let streamer = streamers[profile] else { return }
        connectionText = "Sending media…"
        if layer.kind == .video, let path = layer.assetPath {
            streamer.playVideo(fileURL: URL(fileURLWithPath: path)) { [weak self] success, message in
                Task { @MainActor in
                    self?.stopLive(profile)
                    self?.connectionText = success ? "Video on \(displayName)" : message
                }
            }
        } else if layer.kind == .youtube {
            guard let tools = YouTubeMediaResolver.tools else {
                connectionText = "Install YouTube support in the widget first"
                return
            }
            let input = layer.configValue("url")
            connectionText = "Preparing YouTube video…"
            Task { [self] in
                let browser = layer.configValue("cookiesBrowser", fallback: "none")
                let result = await YouTubeMediaResolver.downloadVideo(input, tools: tools, cookiesFromBrowser: browser, cookiesFile: layer.configValue("cookiesFile"))
                switch result {
                case .success(let fileURL):
                    connectionText = "Sending video…"
                    streamer.playVideo(fileURL: fileURL) { [weak self] success, message in
                        try? FileManager.default.removeItem(at: fileURL)
                        Task { @MainActor in
                            self?.stopLive(profile)
                            self?.connectionText = success ? "Video on \(displayName)" : message
                        }
                    }
                case .failure(let error):
                    connectionText = error.localizedDescription
                }
            }
        } else if layer.kind == .webSnapshot {
            streamer.showWeb(urlString: layer.configValue("url")) { [weak self] success, message in
                Task { @MainActor in
                    self?.stopLive(profile)
                    self?.connectionText = success ? "Web video on \(displayName)" : message
                }
            }
        }
    }

    func sendSelectedNotification() {
        guard let layer = selectedLayer else { return }
        let title = layer.text.isEmpty ? "SubScreen Studio" : layer.text
        let detail = layer.configValue("subtitle", fallback: "Notification")
        if liveDisplays.isEmpty {
            streamers[currentDisplayProfile]?.notify(title: title, detail: detail)
        } else {
            notifyLiveDisplays(title: title, detail: detail)
        }
        connectionText = "Notification sent"
    }

    func save() {
        guard let data = try? JSONEncoder.pretty.encode(project) else { return }
        try? data.write(to: saveURL, options: .atomic)
    }

    func toggleLive() {
        let profile = currentDisplayProfile
        if isDisplayLive(profile) {
            stopLive(profile)
        } else {
            startLive(profile)
        }
    }

    func isDisplayLive(_ profile: StudioDisplayProfile) -> Bool {
        liveDisplays.contains(profile)
    }

    func status(for profile: StudioDisplayProfile) -> String {
        displayStatuses[profile] ?? "Ready"
    }

    func liveSceneName(for profile: StudioDisplayProfile) -> String? {
        guard let id = liveSceneIDs[profile] else { return nil }
        return project.scenes.first(where: { $0.id == id })?.name
    }

    func startLive(_ profile: StudioDisplayProfile, sceneID: UUID? = nil) {
        let chosenID = sceneID
            ?? (currentScene?.resolvedOutputDisplay == profile ? currentScene?.id : nil)
            ?? liveSceneIDs[profile]
            ?? project.scenes.first(where: { $0.resolvedOutputDisplay == profile })?.id
        guard let chosenID else {
            displayStatuses[profile] = "No \(profile.shortTitle) scene"
            refreshConnectionText()
            return
        }
        liveSceneIDs[profile] = chosenID
        liveDisplays.insert(profile)
        reconnectLiveOutput(profile)
    }

    func startBothDisplays() {
        startLive(.d92)
        startLive(.dq288)
    }

    func stopLive(_ profile: StudioDisplayProfile) {
        streamTimers[profile]?.invalidate()
        streamTimers[profile] = nil
        streamers[profile]?.stop()
        rendersInFlight.remove(profile)
        liveDisplays.remove(profile)
        displayStatuses[profile] = "Stopped"
        prepareLiveVideoFrames()
        refreshConnectionText()
    }

    func stopAllDisplays() {
        StudioDisplayProfile.allCases.forEach(stopLive)
        OutputVideoFrameCenter.shared.stopAll()
        connectionText = "Preview"
    }

    func brightness(for profile: StudioDisplayProfile) -> Double {
        Double(brightnessValues[profile] ?? 80)
    }

    func setBrightness(_ value: Double, for profile: StudioDisplayProfile) {
        let percent = min(max(Int(value.rounded()), 0), 100)
        brightnessValues[profile] = percent
        UserDefaults.standard.set(percent, forKey: "displayBrightness.\(profile.rawValue)")
        brightnessTasks[profile]?.cancel()
        let task = DispatchWorkItem { [weak self] in
            Task { @MainActor in self?.applyBrightness(percent, to: profile) }
        }
        brightnessTasks[profile] = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: task)
    }

    private func applyBrightness(_ percent: Int, to profile: StudioDisplayProfile) {
        guard let streamer = streamers[profile] else { return }
        if isDisplayLive(profile) {
            streamer.setBrightness(percent: percent) { [weak self] success in
                guard !success else { return }
                Task { @MainActor in self?.displayStatuses[profile] = "Brightness unavailable" }
            }
            return
        }
        displayStatuses[profile] = "Adjusting brightness…"
        streamer.probe(driverID: profile.driverID) { [weak self] available in
            guard available else {
                Task { @MainActor in self?.displayStatuses[profile] = "Not found" }
                return
            }
            streamer.setBrightness(percent: percent) { success in
                Task { @MainActor in
                    self?.displayStatuses[profile] = success ? "Ready • \(percent)%" : "Brightness unavailable"
                }
            }
        }
    }

    private static func savedBrightness(for profile: StudioDisplayProfile) -> Int {
        let key = "displayBrightness.\(profile.rawValue)"
        guard UserDefaults.standard.object(forKey: key) != nil else { return 80 }
        return min(max(UserDefaults.standard.integer(forKey: key), 0), 100)
    }

    private func restartLiveOutputs() {
        for profile in liveDisplays { startStreaming(profile) }
    }

    private func reconnectLiveOutput(_ profile: StudioDisplayProfile) {
        streamTimers[profile]?.invalidate()
        streamTimers[profile] = nil
        rendersInFlight.remove(profile)
        guard let sceneID = liveSceneIDs[profile],
              project.scenes.contains(where: { $0.id == sceneID && $0.resolvedOutputDisplay == profile }) else {
            stopLive(profile)
            return
        }
        displayStatuses[profile] = "Connecting…"
        refreshConnectionText()
        streamers[profile]?.probe(driverID: profile.driverID) { [weak self] available in
            Task { @MainActor in
                guard let self,
                      self.isDisplayLive(profile),
                      self.liveSceneIDs[profile] == sceneID else { return }
                if available {
                    self.displayStatuses[profile] = "Live"
                    self.streamers[profile]?.setBrightness(percent: self.brightnessValues[profile] ?? 80) { _ in }
                    self.startStreaming(profile)
                } else {
                    self.liveDisplays.remove(profile)
                    self.displayStatuses[profile] = "Not found"
                }
                self.refreshConnectionText()
            }
        }
    }

    private func startStreaming(_ profile: StudioDisplayProfile) {
        guard isDisplayLive(profile), let scene = liveScene(for: profile) else { return }
        let effectiveFPS = streamingFPS(for: scene, profile: profile)
        if currentDisplayProfile == profile { OutputPerformanceMonitor.shared.targetFPS = effectiveFPS }
        prepareLiveVideoFrames()
        renderAndSend(profile)
        streamTimers[profile]?.invalidate()
        streamTimers[profile] = Timer.scheduledTimer(withTimeInterval: 1 / effectiveFPS, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isDisplayLive(profile) else { return }
                let editingThisOutput = self.layerInteractionDepth > 0
                    && self.selectedSceneID == self.liveSceneIDs[profile]
                guard !editingThisOutput else { return }
                self.renderAndSend(profile)
            }
        }
        streamTimers[profile]?.tolerance = min(0.1, 0.12 / effectiveFPS)
    }

    private func liveScene(for profile: StudioDisplayProfile) -> StudioScene? {
        guard let id = liveSceneIDs[profile] else { return nil }
        return project.scenes.first(where: { $0.id == id })
    }

    private func prepareLiveVideoFrames() {
        let scenes = liveDisplays.compactMap { liveScene(for: $0) }
        if scenes.isEmpty { OutputVideoFrameCenter.shared.stopAll() }
        else {
            let maximumFPS = liveDisplays.compactMap { profile in
                liveScene(for: profile).map { streamingFPS(for: $0, profile: profile) }
            }.max() ?? 1
            OutputVideoFrameCenter.shared.prepare(scenes: scenes, maxFPS: maximumFPS)
        }
    }

    /// The FPS field is a quality ceiling. Static dashboards do not benefit
    /// from being rebuilt and JPEG-encoded 30–60 times every second, while
    /// video keeps the requested cadence and music remains visually smooth.
    private func streamingFPS(for scene: StudioScene, profile: StudioDisplayProfile) -> Double {
        let requested = min(max(outputFPS, 1), profile.maxFPS)
        let kinds = Set(scene.layers.lazy.filter { !$0.isHidden }.map(\.kind))
        if !kinds.isDisjoint(with: [.video, .youtube]) { return requested }
        if kinds.contains(.audioVisualizer) { return min(requested, 20) }
        if !kinds.isDisjoint(with: [.nowPlaying, .lyrics]) { return min(requested, 10) }
        if kinds.contains(.windowCapture) { return min(requested, 5) }
        if !kinds.isDisjoint(with: [
            .clock, .focusTimer, .systemMonitor, .networkSpeed, .temperature,
            .fps, .powerSupply, .screenTime, .environment
        ]) { return min(requested, 2) }
        return min(requested, 1)
    }

    private func notifyLiveDisplays(title: String, detail: String) {
        for profile in liveDisplays {
            streamers[profile]?.notify(title: title, detail: detail)
        }
    }

    private func refreshConnectionText() {
        let live = StudioDisplayProfile.allCases.filter { isDisplayLive($0) }
        switch live.count {
        case 0: connectionText = "Preview"
        case 1: connectionText = "\(live[0].shortTitle) • \(status(for: live[0]))"
        default: connectionText = "\(live.count) displays live"
        }
    }

    private func applyArtworkBackground(_ image: NSImage) {
        guard let sceneIndex,
              project.scenes[sceneIndex].automaticallyMatchArtwork == true else { return }
        let sample = NSImage(size: NSSize(width: 1, height: 1))
        sample.lockFocus()
        image.draw(in: NSRect(x: 0, y: 0, width: 1, height: 1), from: .zero, operation: .copy, fraction: 1)
        sample.unlockFocus()
        guard let data = sample.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: data),
              let color = bitmap.colorAt(x: 0, y: 0)?.usingColorSpace(.sRGB) else { return }
        let red = Int(min(max(color.redComponent * 0.34, 0), 1) * 255)
        let green = Int(min(max(color.greenComponent * 0.34, 0), 1) * 255)
        let blue = Int(min(max(color.blueComponent * 0.34, 0), 1) * 255)
        let hex = String(format: "#%02X%02X%02X", red, green, blue)
        guard project.scenes[sceneIndex].backgroundHex != hex else { return }
        project.scenes[sceneIndex].backgroundHex = hex
        save()
    }

    func setAutomaticallyMatchArtwork(_ enabled: Bool) {
        guard let sceneIndex else { return }
        project.scenes[sceneIndex].automaticallyMatchArtwork = enabled
        save()
        if enabled, let artwork = NowPlayingMonitor.shared.artwork { applyArtworkBackground(artwork) }
    }

    private func renderAndSend(_ profile: StudioDisplayProfile) {
        guard !rendersInFlight.contains(profile),
              let scene = liveScene(for: profile),
              scene.resolvedOutputDisplay == profile else { return }
        let sceneID = scene.id
        rendersInFlight.insert(profile)
        let outputSize = profile.canvasSize
        let renderer = ImageRenderer(content: RotatedSceneOutputView(scene: scene))
        renderer.proposedSize = ProposedViewSize(width: outputSize.width, height: outputSize.height)
        renderer.scale = 1
        guard let cgImage = renderer.cgImage else {
            rendersInFlight.remove(profile)
            return
        }
        let effectiveFPS = streamingFPS(for: scene, profile: profile)
        let quality = effectiveFPS >= 45 ? 0.70 : 0.82
        Task { [weak self] in
            let jpeg = await Task.detached(priority: .userInitiated) { () -> Data? in
                autoreleasepool {
                    let bitmap = NSBitmapImageRep(cgImage: cgImage)
                    return bitmap.representation(using: .jpeg, properties: [.compressionFactor: quality])
                }
            }.value
            guard let self, let jpeg else {
                self?.rendersInFlight.remove(profile)
                return
            }
            guard self.isDisplayLive(profile), self.liveSceneIDs[profile] == sceneID,
                  let streamer = self.streamers[profile] else {
                self.rendersInFlight.remove(profile)
                return
            }
            streamer.send(jpeg: jpeg) { [weak self] delivered in
                Task { @MainActor in
                    self?.rendersInFlight.remove(profile)
                    if delivered, self?.currentDisplayProfile == profile {
                        OutputPerformanceMonitor.shared.recordDeliveredFrame()
                    }
                }
            }
        }
    }

    func refreshWeather() async {
        let weatherLayers = project.scenes.flatMap(\.layers).filter { $0.kind == .weather }
        for layer in weatherLayers {
            var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
            components.queryItems = [
                URLQueryItem(name: "latitude", value: String(layer.latitude)),
                URLQueryItem(name: "longitude", value: String(layer.longitude)),
                URLQueryItem(name: "current", value: "temperature_2m,weather_code,is_day"),
                URLQueryItem(name: "timezone", value: "auto")
            ]
            guard let url = components.url,
                  let (data, _) = try? await URLSession.shared.data(from: url),
                  let response = try? JSONDecoder().decode(WeatherResponse.self, from: data) else { continue }
            for sceneIndex in project.scenes.indices {
                guard let layerIndex = project.scenes[sceneIndex].layers.firstIndex(where: { $0.id == layer.id }) else { continue }
                project.scenes[sceneIndex].layers[layerIndex].weatherTemperature = response.current.temperature2m
                project.scenes[sceneIndex].layers[layerIndex].weatherCode = response.current.weatherCode
                project.scenes[sceneIndex].layers[layerIndex].weatherIsDay = response.current.isDay == 1
            }
        }
        save()
    }

    private static let videoExtensions = Set(["mp4", "mov", "m4v", "webm"])
}

/// The editor uses upright logical coordinates. Live output rotates that
/// composition into the controller's fixed physical pixel grid.
private struct RotatedSceneOutputView: View {
    let scene: StudioScene

    var body: some View {
        let physical = scene.resolvedOutputDisplay.canvasSize
        let logical = scene.canvasSize
        ZStack {
            Color(studioHex: scene.backgroundHex)
            SceneOutputView(scene: scene, canvasSize: logical)
                .frame(width: logical.width, height: logical.height)
                .rotationEffect(.degrees(Double(scene.resolvedOutputRotation.rawValue)))
        }
        .frame(width: physical.width, height: physical.height)
        .clipped()
    }
}

extension JSONEncoder {
    static var pretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

final class SSPStreamer {
    private enum PortState {
        case offline
        case online([[String: Any]])
    }

    private var task: URLSessionDataTask?
    private var activeBaseURL = "http://127.0.0.1:7920"
    private var activeDisplayID = "default"
    private var helperProcesses: [Process] = []

    deinit {
        helperProcesses.filter(\.isRunning).forEach { $0.terminate() }
    }

    func probe(driverID: String, completion: @escaping (Bool) -> Void) {
        // Give simultaneous outputs different preferred ports so pressing
        // “Both” cannot race two bundled servers onto the same socket.
        let ports = driverID == "dq288" ? [7921, 7923, 7920, 7922] : [7920, 7922, 7921, 7923]
        inspectPorts(ports, driverID: driverID, firstFreePort: nil, completion: completion)
    }

    private func inspectPorts(_ ports: [Int], driverID: String, firstFreePort: Int?, completion: @escaping (Bool) -> Void) {
        guard let port = ports.first else {
            guard let freePort = firstFreePort, startBundledServer(port: freePort, driverID: driverID) else {
                completion(false)
                return
            }
            waitForBundledServer(port: freePort, driverID: driverID, attemptsLeft: 20, completion: completion)
            return
        }
        inspect(port: port) { [weak self] state in
            guard let self else { completion(false); return }
            switch state {
            case .offline:
                self.inspectPorts(Array(ports.dropFirst()), driverID: driverID, firstFreePort: firstFreePort ?? port, completion: completion)
            case .online(let displays):
                if let display = displays.first(where: {
                    ($0["driver"] as? String) == driverID && ($0["connected"] as? Bool) == true
                }), let id = display["id"] as? String {
                    self.activeBaseURL = "http://127.0.0.1:\(port)"
                    self.activeDisplayID = id
                    completion(true)
                } else {
                    self.inspectPorts(Array(ports.dropFirst()), driverID: driverID, firstFreePort: firstFreePort, completion: completion)
                }
            }
        }
    }

    private func inspect(port: Int, completion: @escaping (PortState) -> Void) {
        guard let url = URL(string: "http://127.0.0.1:\(port)/api/v1/displays") else {
            completion(.offline)
            return
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 0.45
        task = URLSession.shared.dataTask(with: request) { data, response, _ in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200,
                  let data,
                  let displays = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                completion(.offline)
                return
            }
            completion(.online(displays))
        }
        task?.resume()
    }

    private func startBundledServer(port: Int, driverID: String) -> Bool {
        guard let executable = Bundle.main.resourceURL?.appendingPathComponent("ssp"),
              FileManager.default.isExecutableFile(atPath: executable.path) else { return false }
        let process = Process()
        process.executableURL = executable
        process.arguments = ["serve", "--listen", "127.0.0.1:\(port)", "--driver", driverID]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            helperProcesses.append(process)
            return true
        } catch {
            return false
        }
    }

    private func waitForBundledServer(port: Int, driverID: String, attemptsLeft: Int, completion: @escaping (Bool) -> Void) {
        inspect(port: port) { [weak self] state in
            guard let self else { completion(false); return }
            if case .online(let displays) = state,
               let display = displays.first(where: {
                   ($0["driver"] as? String) == driverID && ($0["connected"] as? Bool) == true
               }), let id = display["id"] as? String {
                self.activeBaseURL = "http://127.0.0.1:\(port)"
                self.activeDisplayID = id
                completion(true)
            } else if attemptsLeft > 1 {
                DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.2) {
                    self.waitForBundledServer(port: port, driverID: driverID, attemptsLeft: attemptsLeft - 1, completion: completion)
                }
            } else {
                completion(false)
            }
        }
    }

    private func endpoint(_ suffix: String) -> URL? {
        let id = activeDisplayID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? activeDisplayID
        return URL(string: "\(activeBaseURL)/api/v1/displays/\(id)/\(suffix)")
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    func send(jpeg: Data, completion: @escaping (Bool) -> Void) {
        guard let url = endpoint("image?fit=cover") else { completion(false); return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = jpeg
        request.setValue("image/jpeg", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 2
        URLSession.shared.dataTask(with: request) { _, response, _ in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            completion((200..<300).contains(status))
        }.resume()
    }

    func setBrightness(percent: Int, completion: @escaping (Bool) -> Void) {
        guard let url = endpoint("brightness") else { completion(false); return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "percent": min(max(percent, 0), 100)
        ])
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 2
        URLSession.shared.dataTask(with: request) { _, response, _ in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            completion((200..<300).contains(status))
        }.resume()
    }

    func notify(title: String, detail: String) {
        guard let url = endpoint("notify") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "text": title,
            "detail": detail,
            "style": "banner",
            "color": "#3B82F6",
            "seconds": 6
        ])
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        URLSession.shared.dataTask(with: request).resume()
    }

    func playVideo(fileURL: URL, completion: @escaping (Bool, String) -> Void) {
        guard FileManager.default.fileExists(atPath: fileURL.path),
              let url = endpoint("image?fit=contain") else {
            completion(false, "Video file unavailable")
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30
        URLSession.shared.uploadTask(with: request, fromFile: fileURL) { data, response, error in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let message = data.flatMap { String(data: $0, encoding: .utf8) } ?? error?.localizedDescription ?? "ssp is offline"
            completion((200..<300).contains(status), message)
        }.resume()
    }

    func showWeb(urlString: String, completion: @escaping (Bool, String) -> Void) {
        guard let endpoint = endpoint("web"),
              let sourceURL = URL(string: urlString), ["http", "https"].contains(sourceURL.scheme?.lowercased() ?? "") else {
            completion(false, "Enter a valid web address")
            return
        }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["url": sourceURL.absoluteString])
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 10
        URLSession.shared.dataTask(with: request) { data, response, error in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let message = data.flatMap { String(data: $0, encoding: .utf8) } ?? error?.localizedDescription ?? "ssp is offline"
            completion((200..<300).contains(status), message)
        }.resume()
    }
}
