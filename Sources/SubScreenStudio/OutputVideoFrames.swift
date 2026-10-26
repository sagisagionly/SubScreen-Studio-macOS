import AppKit
import AVFoundation
import CoreImage
import CoreVideo
import QuartzCore

/// Supplies real video frames to the image-based D92 compositor. SwiftUI's
/// ImageRenderer cannot capture AVPlayerView or WKWebView, so the output path
/// reads pixel buffers directly from AVPlayer instead of substituting a card.
final class OutputVideoFrameCenter: @unchecked Sendable {
    static let shared = OutputVideoFrameCenter()

    private final class Entry {
        let signature: String
        let player: AVPlayer
        let output: AVPlayerItemVideoOutput
        var endObserver: NSObjectProtocol?

        init(signature: String, player: AVPlayer, output: AVPlayerItemVideoOutput) {
            self.signature = signature
            self.player = player
            self.output = output
        }
    }

    private let lock = NSLock()
    private var entries: [UUID: Entry] = [:]
    private var frames: [UUID: NSImage] = [:]
    private var pendingSignatures: [UUID: String] = [:]
    private var timer: DispatchSourceTimer?
    private var tickerFPS: Double = 30
    private let renderQueue = DispatchQueue(label: "com.subscreen.studio.video-frames", qos: .userInitiated)
    private let ciContext = CIContext(options: [.cacheIntermediates: false])

    private init() {}

    @MainActor
    func prepare(scene: StudioScene, maxFPS: Double = 30) {
        prepare(scenes: [scene], maxFPS: maxFPS)
    }

    /// Keeps players for every independently live scene. Preparing one output
    /// must not tear down video that is still playing on the other display.
    @MainActor
    func prepare(scenes: [StudioScene], maxFPS: Double = 30) {
        setTickerFPS(maxFPS)
        let mediaLayers = scenes.flatMap(\.layers).filter {
            !$0.isHidden && ($0.kind == .video || $0.kind == .youtube)
        }
        let activeIDs = Set(mediaLayers.map(\.id))
        removeEntries(notIn: activeIDs)

        for layer in mediaLayers {
            let signature = Self.signature(for: layer)
            lock.lock()
            let unchanged = entries[layer.id]?.signature == signature || pendingSignatures[layer.id] == signature
            if !unchanged { pendingSignatures[layer.id] = signature }
            lock.unlock()
            guard !unchanged else { continue }

            if layer.kind == .video, let path = layer.assetPath,
               FileManager.default.fileExists(atPath: path) {
                install(url: URL(fileURLWithPath: path), layerID: layer.id, signature: signature)
            } else if layer.kind == .youtube, let tools = YouTubeMediaResolver.tools {
                let input = layer.configValue("url")
                let browser = layer.configValue("cookiesBrowser", fallback: "none")
                let file = layer.configValue("cookiesFile")
                Task { [weak self] in
                    let result = await YouTubeMediaResolver.resolveStream(
                        input,
                        tools: tools,
                        cookiesFromBrowser: browser,
                        cookiesFile: file
                    )
                    guard let self else { return }
                    if case .success(let url) = result {
                        await MainActor.run {
                            self.install(url: url, layerID: layer.id, signature: signature)
                        }
                    } else {
                        self.clearPending(layerID: layer.id, signature: signature)
                    }
                }
            }
        }
        startTickerIfNeeded()
    }

    func image(for layerID: UUID) -> NSImage? {
        lock.lock(); defer { lock.unlock() }
        return frames[layerID]
    }

    @MainActor
    func stopAll() {
        lock.lock()
        let oldEntries = Array(entries.values)
        entries.removeAll()
        frames.removeAll()
        pendingSignatures.removeAll()
        let oldTimer = timer
        timer = nil
        lock.unlock()
        oldTimer?.cancel()
        oldEntries.forEach { entry in
            entry.player.pause()
            if let observer = entry.endObserver { NotificationCenter.default.removeObserver(observer) }
        }
    }

    @MainActor
    private func install(url: URL, layerID: UUID, signature: String) {
        lock.lock()
        guard pendingSignatures[layerID] == signature else { lock.unlock(); return }
        lock.unlock()

        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ])
        let item = AVPlayerItem(url: url)
        item.add(output)
        item.preferredForwardBufferDuration = 3
        let player = AVPlayer(playerItem: item)
        player.isMuted = true
        player.actionAtItemEnd = .none
        let entry = Entry(signature: signature, player: player, output: output)
        entry.endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak player] _ in
            player?.seek(to: .zero)
            player?.play()
        }

        lock.lock()
        let previous = entries[layerID]
        entries[layerID] = entry
        pendingSignatures[layerID] = nil
        frames[layerID] = nil
        lock.unlock()
        previous?.player.pause()
        if let observer = previous?.endObserver { NotificationCenter.default.removeObserver(observer) }
        player.play()
        startTickerIfNeeded()
    }

    @MainActor
    private func removeEntries(notIn activeIDs: Set<UUID>) {
        lock.lock()
        let removed = entries.filter { !activeIDs.contains($0.key) }
        removed.keys.forEach {
            entries[$0] = nil
            frames[$0] = nil
            pendingSignatures[$0] = nil
        }
        let oldTimer: DispatchSourceTimer?
        if entries.isEmpty && pendingSignatures.isEmpty {
            oldTimer = timer
            timer = nil
        } else {
            oldTimer = nil
        }
        lock.unlock()
        oldTimer?.cancel()
        removed.values.forEach {
            $0.player.pause()
            if let observer = $0.endObserver { NotificationCenter.default.removeObserver(observer) }
        }
    }

    private func startTickerIfNeeded() {
        lock.lock()
        guard timer == nil, !entries.isEmpty || !pendingSignatures.isEmpty else { lock.unlock(); return }
        let source = DispatchSource.makeTimerSource(queue: renderQueue)
        let interval = 1.0 / tickerFPS
        source.schedule(deadline: .now(), repeating: interval, leeway: .milliseconds(max(2, Int(interval * 180))))
        source.setEventHandler { [weak self] in self?.captureFrames() }
        timer = source
        lock.unlock()
        source.resume()
    }

    private func captureFrames() {
        lock.lock()
        let snapshot = entries
        lock.unlock()
        for (id, entry) in snapshot {
            let frame: NSImage? = autoreleasepool {
                // Convert host time through the video output so the sampled frame
                // is the one AVPlayer is actually presenting, not a nearby seek
                // time that can repeatedly report no new pixel buffer.
                let time = entry.output.itemTime(forHostTime: CACurrentMediaTime())
                guard entry.output.hasNewPixelBuffer(forItemTime: time),
                      let buffer = entry.output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil) else { return nil }
                let image = CIImage(cvPixelBuffer: buffer)
                guard let cgImage = ciContext.createCGImage(image, from: image.extent) else { return nil }
                return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
            }
            if let frame {
            lock.lock(); frames[id] = frame; lock.unlock()
            }
        }
    }

    private func setTickerFPS(_ requestedFPS: Double) {
        let next = min(max(requestedFPS, 1), 30)
        lock.lock()
        guard abs(next - tickerFPS) > 0.5 else { lock.unlock(); return }
        tickerFPS = next
        let oldTimer = timer
        timer = nil
        let shouldRestart = !entries.isEmpty || !pendingSignatures.isEmpty
        lock.unlock()
        oldTimer?.cancel()
        if shouldRestart { startTickerIfNeeded() }
    }

    private func clearPending(layerID: UUID, signature: String) {
        lock.lock()
        if pendingSignatures[layerID] == signature { pendingSignatures[layerID] = nil }
        let oldTimer: DispatchSourceTimer?
        if entries.isEmpty && pendingSignatures.isEmpty {
            oldTimer = timer
            timer = nil
        } else {
            oldTimer = nil
        }
        lock.unlock()
        oldTimer?.cancel()
    }

    private static func signature(for layer: StudioLayer) -> String {
        [layer.kind.rawValue, layer.assetPath ?? "", layer.configValue("url"),
         layer.configValue("cookiesBrowser"), layer.configValue("cookiesFile")].joined(separator: "|")
    }
}
