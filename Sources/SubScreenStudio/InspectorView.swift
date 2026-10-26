import AppKit
import SwiftUI

struct InspectorView: View {
    @EnvironmentObject private var store: StudioStore
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 0) {
            Picker("Inspector", selection: $store.inspectorTab) {
                Text("Scene").tag(0)
                Text("Layer").tag(1)
            }
            .pickerStyle(.segmented)
            .padding(12)

            Divider().opacity(0.35)
            ScrollView {
                if store.inspectorTab == 0 {
                    SceneInspector()
                } else if store.selectedLayer != nil {
                    LayerInspector()
                } else {
                    ContentUnavailableView("No layer selected", systemImage: "square.dashed", description: Text("Select a layer on the canvas."))
                        .padding(.top, 80)
                }
            }
        }
        .background(StudioTheme.panel(colorScheme))
    }
}

struct SceneInspector: View {
    @EnvironmentObject private var store: StudioStore
    @ObservedObject private var launchAtLogin = LaunchAtLoginController.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            InspectorSection("SCENE") {
                LabeledContent("Name") {
                    TextField("Scene", text: store.sceneBinding(\.name, fallback: "Scene"))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 160)
                }
                LabeledContent("Background") {
                    HexColorField(value: store.sceneBinding(\.backgroundHex, fallback: "#090A0F"))
                }
                Toggle("Match background to album artwork", isOn: Binding(
                    get: { store.currentScene?.automaticallyMatchArtwork == true },
                    set: { store.setAutomaticallyMatchArtwork($0) }
                ))
            }
            InspectorSection("OUTPUT") {
                LabeledContent("Display") {
                    Picker("Display", selection: Binding(
                        get: { store.currentDisplayProfile },
                        set: { store.setSceneDisplayProfile($0) }
                    )) {
                        ForEach(StudioDisplayProfile.allCases) { profile in
                            Text(profile.title).tag(profile)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 174)
                }
                LabeledContent("Resolution") {
                    Text("\(Int(store.canvasSize.width)) × \(Int(store.canvasSize.height))")
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Orientation") {
                    Picker("Orientation", selection: Binding(
                        get: { store.currentScene?.resolvedOutputRotation ?? .degrees0 },
                        set: { store.setSceneRotation($0) }
                    )) {
                        ForEach(StudioDisplayRotation.allCases) { rotation in
                            Text(rotation.title).tag(rotation)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 110)
                }
                LabeledContent("Brightness") {
                    HStack(spacing: 7) {
                        Slider(value: brightnessBinding, in: 0...100, step: 1)
                            .frame(width: 104)
                        TextField("%", value: brightnessBinding, format: .number.precision(.fractionLength(0)))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 48)
                            .multilineTextAlignment(.trailing)
                    }
                }
                LabeledContent("Transport") { Text("sub-screen-player").foregroundStyle(.secondary) }
                LabeledContent("Output FPS") {
                    TextField("FPS", value: $store.outputFPS, format: .number.precision(.fractionLength(0)))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 70)
                        .multilineTextAlignment(.trailing)
                }
                Text("Maximum 1–60 FPS. Video uses the selected rate; static and music scenes automatically use fewer frames to keep the Mac cool and responsive.")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                Toggle("Show alignment grid", isOn: $store.showGrid)
                Toggle("Snap layers to grid", isOn: $store.snapToGrid)
                Text("Each scene keeps its own display and orientation. Brightness is remembered per physical display.")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            InspectorSection("SCENE SCHEDULER") {
                Toggle("Rotate scenes automatically", isOn: $store.autoRotateScenes)
                if store.autoRotateScenes {
                    LabeledContent("Every") {
                        HStack(spacing: 5) {
                            TextField("Seconds", value: $store.sceneRotationSeconds, format: .number.precision(.fractionLength(0)))
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 70)
                            Text("sec").foregroundStyle(.secondary)
                        }
                    }
                }
                Text("Scenes rotate in sidebar order. The minimum interval is 10 seconds.")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            InspectorSection("STARTUP") {
                Toggle("Launch SubScreen Studio at login", isOn: Binding(
                    get: { launchAtLogin.enabled },
                    set: { launchAtLogin.setEnabled($0) }
                ))
                Text(launchAtLogin.statusText)
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            InspectorSection("QUICK ADD") {
                LazyVGrid(columns: [.init(.flexible()), .init(.flexible())], spacing: 8) {
                    quickAdd(.clock)
                    quickAdd(.weather)
                    quickAdd(.codex)
                    quickAdd(.text)
                    quickAdd(.shape)
                }
            }
        }
        .padding(14)
    }

    private var brightnessBinding: Binding<Double> {
        Binding(
            get: { store.brightness(for: store.currentDisplayProfile) },
            set: { store.setBrightness($0, for: store.currentDisplayProfile) }
        )
    }

    private func quickAdd(_ kind: LayerKind) -> some View {
        Button { store.addLayer(kind) } label: {
            VStack(spacing: 7) {
                Image(systemName: kind.symbol).font(.system(size: 18))
                Text(kind.title).font(.system(size: 10, weight: .medium))
            }
            .frame(maxWidth: .infinity)
            .frame(height: 62)
            .background(.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
    }
}

struct LayerInspector: View {
    @EnvironmentObject private var store: StudioStore
    @AppStorage("lyricsProvider") private var lyricsProvider = "automatic"

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            InspectorSection("LAYER") {
                LabeledContent("Name") {
                    TextField("Layer", text: store.layerBinding(\.name, fallback: "Layer"))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 160)
                }
                if let layer = store.selectedLayer {
                    Label(layer.kind.title, systemImage: layer.kind.symbol)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                Toggle("Visible", isOn: Binding(
                    get: { !(store.selectedLayer?.isHidden ?? false) },
                    set: { hidden in
                        guard let id = store.selectedLayerID else { return }
                        store.updateLayer(id) { $0.isHidden = !hidden }
                    }
                ))
                Toggle("Lock position", isOn: store.layerBinding(\.isLocked, fallback: false))
            }

            InspectorSection("WIDGET SIZE") {
                HStack(spacing: 7) {
                    ForEach(WidgetSizePreset.allCases) { preset in
                        Button {
                            store.applySizePreset(preset)
                        } label: {
                            VStack(spacing: 5) {
                                Image(systemName: preset.symbol)
                                    .font(.system(size: 15, weight: .medium))
                                Text(preset.title)
                                    .font(.system(size: 9, weight: .semibold))
                            }
                            .foregroundStyle(store.selectedLayer?.sizePreset == preset ? Color.white : Color.primary)
                            .frame(maxWidth: .infinity, minHeight: 48)
                            .background(store.selectedLayer?.sizePreset == preset ? Color.accentColor : Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }
                if store.selectedLayer?.sizePreset == nil {
                    Label("Custom size", systemImage: "aspectratio")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }

            InspectorSection("LAYOUT") {
                numberRow("X", keyPath: \.frame.x)
                numberRow("Y", keyPath: \.frame.y)
                numberRow("Width", keyPath: \.frame.width)
                numberRow("Height", keyPath: \.frame.height)
                HStack {
                    Button { if let id = store.selectedLayerID { store.moveLayerInStack(id, delta: 1) } } label: {
                        Label("Forward", systemImage: "square.2.layers.3d.top.filled")
                    }
                    Button { if let id = store.selectedLayerID { store.moveLayerInStack(id, delta: -1) } } label: {
                        Label("Back", systemImage: "square.2.layers.3d.bottom.filled")
                    }
                }
                .font(.system(size: 11))
                Toggle("Lock corner aspect ratio", isOn: $store.preserveAspectRatio)
                if store.selectedLayer?.isLocked == true {
                    Button("Unlock to move and resize") {
                        guard let id = store.selectedLayerID else { return }
                        store.updateLayer(id) { $0.isLocked = false }
                    }
                    .buttonStyle(.borderedProminent)
                }
                Text("OBS-style transform: corner handles keep the aspect ratio; side handles stretch one axis. Hold Shift for a free corner resize, Option to resize from center, or Control to temporarily disable snapping.")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                Text("Keyboard: Arrow keys move 1 px after clicking the canvas; Shift + Arrow moves 10 px. Option + Arrow works from anywhere in the editor.")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                HStack(spacing: 5) {
                    Button { store.alignSelected(horizontal: .left) } label: { Image(systemName: "align.horizontal.left") }
                    Button { store.alignSelected(horizontal: .center) } label: { Image(systemName: "align.horizontal.center") }
                    Button { store.alignSelected(horizontal: .right) } label: { Image(systemName: "align.horizontal.right") }
                    Divider().frame(height: 16)
                    Button { store.alignSelected(vertical: .top) } label: { Image(systemName: "align.vertical.top") }
                    Button { store.alignSelected(vertical: .middle) } label: { Image(systemName: "align.vertical.center") }
                    Button { store.alignSelected(vertical: .bottom) } label: { Image(systemName: "align.vertical.bottom") }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            InspectorSection("APPEARANCE") {
                sliderAndNumber("Opacity", binding: store.layerBinding(\.opacity, fallback: 1), range: 0...1, step: 0.01)
                sliderAndNumber("Corner radius", binding: store.layerBinding(\.cornerRadius, fallback: 24), range: 0...240, step: 1)
                LabeledContent("Background") {
                    HexColorField(value: store.layerBinding(\.backgroundHex, fallback: "#171922"))
                }
                LabeledContent("Text") {
                    HexColorField(value: store.layerBinding(\.foregroundHex, fallback: "#FFFFFF"))
                }
            }

            if let kind = store.selectedLayer?.kind {
                kindControls(kind)
            }

            Button(role: .destructive) { store.deleteSelectedLayer() } label: {
                Label("Delete Layer", systemImage: "trash")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        }
        .padding(14)
    }

    @ViewBuilder
    private func kindControls(_ kind: LayerKind) -> some View {
        switch kind {
        case .weather:
            InspectorSection("WEATHER") {
                WeatherLocationSearch()
                Text(store.selectedLayer?.locationName ?? "No city selected")
                    .font(.system(size: 11, weight: .medium))
                LabeledContent("Temperature") {
                    Picker("Temperature", selection: store.configBinding("temperatureUnit", fallback: "celsius")) {
                        Text("Celsius (°C)").tag("celsius")
                        Text("Fahrenheit (°F)").tag("fahrenheit")
                    }
                    .labelsHidden().frame(width: 150)
                }
                Button("Refresh Weather") {
                    Task { await store.refreshWeather() }
                }
                .buttonStyle(.bordered)
            }
        case .codex:
            CodexConnectionInspector()
        case .text:
            InspectorSection("TEXT") {
                TextEditor(text: store.layerBinding(\.text, fallback: "Text"))
                    .font(.system(size: 12))
                    .frame(height: 70)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background(.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 7))
                numberField("Font size", binding: store.layerBinding(\.fontSize, fallback: 54))
                LabeledContent("Font") {
                    Picker("Font", selection: store.layerBinding(\.fontName, fallback: nil)) {
                        Text("System Rounded").tag(String?.none)
                        ForEach(Self.preferredFonts, id: \.self) { family in
                            Text(family).font(.custom(family, size: 12)).tag(Optional(family))
                        }
                    }
                    .labelsHidden()
                    .frame(width: 155)
                }
            }
        case .clock:
            InspectorSection("CLOCK") {
                numberField("Font size", binding: store.layerBinding(\.fontSize, fallback: 54))
                LabeledContent("Time zone") {
                    Picker("Time zone", selection: store.configBinding("timeZone")) {
                        Text("System time zone").tag("")
                        ForEach(Self.timeZoneIdentifiers, id: \.self) { identifier in
                            Text(identifier.replacingOccurrences(of: "_", with: " ")).tag(identifier)
                        }
                    }
                    .labelsHidden().frame(width: 155)
                }
                Text("The date follows your Mac’s language and the selected time zone.")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
        case .image, .video:
            InspectorSection("MEDIA") {
                Text(store.selectedLayer?.assetPath ?? "No file")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                if !store.selectedMediaExists {
                    Label("File is missing", systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.orange)
                }
                HStack {
                    Button("Replace…") { store.chooseMediaFiles(replacingSelection: true) }
                        .buttonStyle(.bordered)
                    Button("Show in Finder") { store.revealSelectedMedia() }
                        .buttonStyle(.bordered)
                        .disabled(!store.selectedMediaExists)
                }
                if kind == .video {
                    Button { store.playSelectedMediaOnDisplay() } label: {
                        Label("Play Full-Screen on D92", systemImage: "play.display")
                    }
                    .buttonStyle(.borderedProminent)
                    Text("Video previews loop silently. Go Live composites the moving video into the D92 output with the same crop and corner radius.")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
        case .nowPlaying:
            InspectorSection("NOW PLAYING") {
                Label("Apple Music", systemImage: "music.note")
                Label("Spotify", systemImage: "waveform")
                Label("YouTube Music in Safari, Chrome or Edge", systemImage: "play.rectangle")
                Text("Playback is detected automatically. macOS may ask permission to read Music or your browser the first time.")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
        case .powerSupply:
            PowerSupplyInspector()
        case .lyrics:
            InspectorSection("LYRICS") {
                numberField("Font size", binding: store.layerBinding(\.fontSize, fallback: 64))
                LabeledContent("Source") {
                    Picker("Source", selection: $lyricsProvider) {
                        Text("Automatic — accuracy first").tag("automatic")
                        Text("YouTube Music").tag("ytmusic")
                        Text("LRCLIB").tag("lrclib")
                        Text("Musixmatch").tag("musixmatch")
                        Text("Megalobiz (Beta)").tag("megalobiz")
                    }
                    .labelsHidden().frame(width: 155)
                }
                .onChange(of: lyricsProvider) { _, _ in NowPlayingMonitor.shared.reloadMediaMetadata() }
                Text(NowPlayingMonitor.shared.lyricsStatus)
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                Button("Retry Current Song") { NowPlayingMonitor.shared.reloadMediaMetadata() }
                    .buttonStyle(.bordered)
                Text("Apple Music and Spotify supply exact song metadata; Automatic searches YouTube Music, LRCLIB, Musixmatch, then Megalobiz. Original-language lyrics stay in memory only and are erased when the app closes.")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                Divider()
                Button("Use local .lrc instead…") { store.chooseLyricsFile() }
                    .buttonStyle(.bordered)
                TextEditor(text: store.layerBinding(\.text, fallback: "Lyrics"))
                    .frame(height: 58)
                    .scrollContentBackground(.hidden)
                    .padding(5)
                    .background(.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 7))
            }
        case .focusTimer:
            InspectorSection("FOCUS TIMER") {
                numberField("Minutes", binding: store.numberConfigBinding("minutes", fallback: 25))
                Button { store.startFocusTimer() } label: {
                    Label("Start Focus Session", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
            }
        case .youtube:
            InspectorSection("YOUTUBE") {
                TextField("YouTube URL", text: store.configBinding("url"))
                    .textFieldStyle(.roundedBorder)
                LabeledContent("Signed-in browser") {
                    Picker("Signed-in browser", selection: store.configBinding("cookiesBrowser", fallback: "auto")) {
                        Text("Automatic").tag("auto")
                        Text("No browser session").tag("none")
                        Text("Safari").tag("safari")
                        Text("Chrome").tag("chrome")
                        Text("Firefox").tag("firefox")
                        Text("Edge").tag("edge")
                        Text("Brave").tag("brave")
                    }
                    .labelsHidden().frame(width: 155)
                }
                Button("Open YouTube Sign In") { openYouTubeSignIn() }
                .buttonStyle(.bordered)
                Button("Connect & Save Browser Session") { store.saveSelectedYouTubeBrowserSession() }
                    .buttonStyle(.borderedProminent)
                    .disabled(store.selectedLayer?.configValue("cookiesBrowser", fallback: "auto") == "none")
                if !store.youtubeSessionStatus.isEmpty {
                    Label(store.youtubeSessionStatus, systemImage: YouTubeMediaResolver.hasPersistentSession ? "checkmark.circle.fill" : "info.circle")
                        .font(.system(size: 10))
                        .foregroundStyle(YouTubeMediaResolver.hasPersistentSession ? .green : .secondary)
                }
                if store.selectedLayer?.configValue("cookiesBrowser") == "safari" {
                    Button("Open Full Disk Access Settings") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") { NSWorkspace.shared.open(url) }
                    }
                    .buttonStyle(.bordered)
                    Text("Safari stores cookies in a protected container. Add SubScreen Studio to Full Disk Access, enable it, then quit and reopen the app.")
                        .font(.system(size: 10)).foregroundStyle(.orange)
                }
                Button("Import cookies.txt…") { store.chooseYouTubeCookiesFile() }
                    .buttonStyle(.bordered)
                if let path = store.selectedLayer?.configValue("cookiesFile"), !path.isEmpty {
                    Label(URL(fileURLWithPath: path).lastPathComponent, systemImage: "checkmark.circle.fill")
                        .font(.system(size: 10)).foregroundStyle(.green)
                }
                Button { store.playSelectedMediaOnDisplay() } label: {
                    Label("Play Full-Screen on D92", systemImage: "play.display")
                }
                .buttonStyle(.borderedProminent)
                Text("Automatic tries installed browsers only if YouTube requests sign-in. A working session is saved locally and reused when you change videos. Safari may need Full Disk Access; cookies.txt remains available as a fallback.")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
        case .systemMonitor:
            localStatusSection("Live CPU, RAM and Apple GPU utilization. Data stays on this Mac.")
        case .networkSpeed:
            localStatusSection("Live upload and download throughput across active network interfaces.")
        case .temperature:
            TemperatureInspector()
        case .fps:
            localStatusSection("Shows frames actually delivered to sub-screen-player compared with the selected output target.")
        case .windowCapture:
            WindowCaptureInspector()
        case .airPods:
            InspectorSection("AIRPODS") {
                Label(AirPodsMonitor.shared.connectedName ?? "Waiting for AirPods", systemImage: "airpodspro")
                Text("When AirPods or Beats connect, SubScreen Studio shows a connection animation and sends a six-second banner to the D92 through ssp.")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
        case .calendar:
            InspectorSection("CALENDAR") {
                Button("Connect Apple Calendar") { AgendaMonitor.shared.connectCalendar() }
                    .buttonStyle(.borderedProminent)
                Text("Uses the standard macOS Calendar permission. Event data stays on this Mac.")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
        case .reminders:
            InspectorSection("REMINDERS") {
                Button("Connect Apple Reminders") { AgendaMonitor.shared.connectReminders() }
                    .buttonStyle(.borderedProminent)
                Text("Shows up to four incomplete reminders using the standard macOS permission.")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
        case .worldClock:
            InspectorSection("WORLD CLOCKS") {
                worldClockRow(1, fallbackCity: "Shanghai", fallbackZone: "Asia/Shanghai")
                Divider()
                worldClockRow(2, fallbackCity: "London", fallbackZone: "Europe/London")
                Divider()
                worldClockRow(3, fallbackCity: "New York", fallbackZone: "America/New_York")
                Text("Enter any city label and choose its time zone. Leave a city name blank to hide that clock.")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
        case .audioVisualizer:
            InspectorSection("AUDIO VISUALIZER") {
                Label(AudioLevelMonitor.shared.status, systemImage: "waveform")
                Button("Start Live Audio") { AudioLevelMonitor.shared.start() }
                    .buttonStyle(.borderedProminent)
                Text("Uses the Mac microphone so it works with Apple Music, YouTube Music and other audio without installing a virtual audio driver.")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
        case .photoAlbum:
            InspectorSection("PHOTO ALBUM") {
                Button("Choose Image…") { store.chooseMediaFiles(replacingSelection: true) }
                Text("Add several image layers or duplicate the scene to create a rotation.")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
        case .webSnapshot:
            genericControls(urlLabel: "Dashboard URL")
            Button { store.playSelectedMediaOnDisplay() } label: {
                Label("Open Full-Screen on D92", systemImage: "safari")
            }
            .buttonStyle(.borderedProminent)
        case .notification:
            genericControls()
            Button { store.sendSelectedNotification() } label: {
                Label("Send Banner to D92", systemImage: "bell.badge.fill")
            }
            .buttonStyle(.borderedProminent)
            Text("For privacy, macOS does not expose one public feed of every other app's notifications. AirPods alerts are automatic; other apps can send messages through ssp's local notification endpoint.")
                .font(.system(size: 10)).foregroundStyle(.secondary)
        case .rss:
            NewsFeedInspector()
        case .environment:
            InspectorSection("CURRENT AREA") {
                Label(CurrentEnvironmentMonitor.shared.status, systemImage: "location.fill")
                Button("Use My Current Location") { CurrentEnvironmentMonitor.shared.requestLocation() }
                    .buttonStyle(.borderedProminent)
                Text("Uses macOS Location Services and Open-Meteo. Your coordinates are only sent to Open-Meteo for current conditions.")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
        case .screenTime:
            InspectorSection("APP ACTIVITY") {
                Label("Tracked locally", systemImage: "lock.fill")
                Text("Shows foreground app time recorded while SubScreen Studio is running. Apple does not expose the system Screen Time database to ordinary Mac apps.")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
        case .finance, .sports,
             .transit, .github, .smartHome, .chatStatus, .creatorCounter,
             .packageTracker, .messageBoard:
            genericControls()
        case .shape:
            EmptyView()
        }
    }

    @ViewBuilder
    private func localStatusSection(_ description: String) -> some View {
        InspectorSection("LOCAL WIDGET") {
            Label("Ready", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            Text(description).font(.system(size: 10)).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func genericControls(urlLabel: String? = nil) -> some View {
        InspectorSection("CONTENT") {
            LabeledContent("Title") {
                TextField("Title", text: store.layerBinding(\.text, fallback: "Widget"))
                    .textFieldStyle(.roundedBorder).frame(width: 155)
            }
            LabeledContent("Detail") {
                TextField("Detail", text: store.configBinding("subtitle"))
                    .textFieldStyle(.roundedBorder).frame(width: 155)
            }
            LabeledContent("Value") {
                TextField("Value", text: store.configBinding("value"))
                    .textFieldStyle(.roundedBorder).frame(width: 155)
            }
            if let urlLabel {
                TextField(urlLabel, text: store.configBinding("url"))
                    .textFieldStyle(.roundedBorder)
            }
            if store.selectedLayer?.kind.worksLocally == false {
                Label("Manual mode is ready", systemImage: "checkmark.circle")
                    .font(.system(size: 10, weight: .medium)).foregroundStyle(.green)
                Text("Enter values now. Account/API connections will replace them automatically without changing the layout.")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
    }

    private func numberRow(_ name: String, keyPath: WritableKeyPath<StudioLayer, Double>) -> some View {
        let binding = Binding<Double>(
            get: { store.selectedLayer?[keyPath: keyPath] ?? 0 },
            set: { value in
                guard let id = store.selectedLayerID else { return }
                store.updateLayer(id) { layer in
                    layer[keyPath: keyPath] = value
                    let isWidth = (keyPath as AnyKeyPath) == (\StudioLayer.frame.width as AnyKeyPath)
                    let isHeight = (keyPath as AnyKeyPath) == (\StudioLayer.frame.height as AnyKeyPath)
                    guard isWidth || isHeight else { return }
                    var metrics = layer.numericConfig ?? [:]
                    metrics[isWidth ? "designWidth" : "designHeight"] = max(24, value)
                    layer.numericConfig = metrics
                    var config = layer.config ?? [:]
                    config.removeValue(forKey: "sizePreset")
                    layer.config = config
                }
            }
        )
        return numberField(name, binding: binding)
    }

    private func numberField(_ name: String, binding: Binding<Double>) -> some View {
        return LabeledContent(name) {
            TextField(name, value: binding, format: .number.precision(.fractionLength(0...2)))
                .textFieldStyle(.roundedBorder)
                .frame(width: 92)
        }
    }

    private func sliderAndNumber(_ name: String, binding: Binding<Double>, range: ClosedRange<Double>, step: Double) -> some View {
        let boundedBinding = Binding(
            get: { min(max(binding.wrappedValue, range.lowerBound), range.upperBound) },
            set: { binding.wrappedValue = min(max($0, range.lowerBound), range.upperBound) }
        )
        return LabeledContent(name) {
            HStack(spacing: 7) {
                Slider(value: boundedBinding, in: range, step: step)
                .frame(minWidth: 78)
                TextField(name, value: boundedBinding, format: .number.precision(.fractionLength(0...2)))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 58)
                    .multilineTextAlignment(.trailing)
            }
        }
    }

    private func openYouTubeSignIn() {
        guard let url = URL(string: "https://www.youtube.com/signin") else { return }
        let bundleIDs = [
            "safari": "com.apple.Safari", "chrome": "com.google.Chrome",
            "firefox": "org.mozilla.firefox", "edge": "com.microsoft.edgemac",
            "brave": "com.brave.Browser"
        ]
        let browser = store.selectedLayer?.configValue("cookiesBrowser", fallback: "none") ?? "none"
        if let bundleID = bundleIDs[browser],
           let applicationURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            NSWorkspace.shared.open([url], withApplicationAt: applicationURL, configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    @ViewBuilder
    private func worldClockRow(_ index: Int, fallbackCity: String, fallbackZone: String) -> some View {
        LabeledContent("Clock \(index)") {
            VStack(alignment: .trailing, spacing: 6) {
                TextField("City", text: store.configBinding("clockCity\(index)", fallback: fallbackCity))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 155)
                Picker("Time zone", selection: store.configBinding("clockZone\(index)", fallback: fallbackZone)) {
                    ForEach(Self.timeZoneIdentifiers, id: \.self) { identifier in
                        Text(identifier.replacingOccurrences(of: "_", with: " ")).tag(identifier)
                    }
                }
                .labelsHidden()
                .frame(width: 155)
            }
        }
    }

    private static let preferredFonts = NSFontManager.shared.availableFontFamilies.sorted {
        $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
    }

    private static let timeZoneIdentifiers = TimeZone.knownTimeZoneIdentifiers.sorted()
}

private struct WeatherLocationSearch: View {
    @EnvironmentObject private var store: StudioStore
    @State private var query = ""
    @State private var results: [WeatherPlace] = []
    @State private var searching = false

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                TextField("City, Country", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { search() }
                Button { search() } label: { Image(systemName: "magnifyingglass") }
                    .buttonStyle(.bordered)
            }
            if searching { ProgressView().controlSize(.small) }
            ForEach(results.prefix(5)) { place in
                Button {
                    store.setWeatherLocation(place)
                    query = place.displayName
                    results = []
                } label: {
                    HStack {
                        Image(systemName: "mappin.and.ellipse")
                        Text(place.displayName).lineLimit(1)
                        Spacer()
                    }
                    .font(.system(size: 11))
                    .padding(.horizontal, 8)
                    .frame(height: 27)
                    .background(.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func search() {
        let text = query
        searching = true
        Task {
            results = await WeatherSearchService.search(text)
            searching = false
        }
    }
}

private struct CodexConnectionInspector: View {
    @ObservedObject private var codex = CodexBridgeMonitor.shared

    var body: some View {
        InspectorSection("CODEX LIVE") {
            Label(codex.status, systemImage: codex.connected ? "checkmark.circle.fill" : "exclamationmark.circle")
                .foregroundStyle(codex.connected ? .green : .secondary)
            Button("Refresh Usage") { codex.refresh() }
                .buttonStyle(.bordered)
            Text("Usage updates live through the local Codex app-server. Approval alerts cover Codex sessions routed through this bridge; other Codex windows keep their own approval UI.")
                .font(.system(size: 10)).foregroundStyle(.secondary)
        }
    }
}

private struct TemperatureInspector: View {
    @ObservedObject private var monitor = HardwareTemperatureMonitor.shared

    var body: some View {
        InspectorSection("TEMPERATURE SENSORS") {
            Label(monitor.status, systemImage: monitor.isAvailable ? "thermometer.medium" : "wrench.and.screwdriver")
                .font(.system(size: 11))
            if !monitor.isAvailable {
                Button(monitor.installing ? "Installing…" : "Install Sensor Helper") { monitor.installSupport() }
                    .buttonStyle(.borderedProminent)
                    .disabled(monitor.installing)
                Text("One-click installs the open-source macmon helper through Homebrew. It reads Apple Silicon sensors locally without sudo.")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            } else {
                Button("Refresh Now") { monitor.refresh() }.buttonStyle(.bordered)
            }
        }
    }
}

private struct PowerSupplyInspector: View {
    @EnvironmentObject private var store: StudioStore
    @ObservedObject private var monitor = PSUMonitor.shared

    var body: some View {
        InspectorSection("VD1200P TELEMETRY") {
            Label(monitor.status, systemImage: monitor.snapshot.connected ? "checkmark.circle.fill" : "cable.connector.slash")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(monitor.snapshot.connected ? .green : .secondary)
            if !monitor.snapshot.firmware.isEmpty {
                LabeledContent("Firmware", value: monitor.snapshot.firmware)
                    .font(.system(size: 10, design: .monospaced))
            }
            LabeledContent("12V channel A") {
                TextField("12V Channel A", text: store.configBinding("rail12ALabel", fallback: "12V Channel A"))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 145)
            }
            LabeledContent("12V channel B") {
                TextField("12V Channel B", text: store.configBinding("rail12BLabel", fallback: "12V Channel B"))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 145)
            }
            Button("Reconnect") { monitor.start() }
                .buttonStyle(.bordered)
            Text("The VD1200P uses one shared 100 A +12 V rail. The controller reports two 12 V sensor channels but does not identify their modular sockets, so their labels remain editable until they are verified under load.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
    }
}

private struct WindowCaptureInspector: View {
    @EnvironmentObject private var store: StudioStore
    @ObservedObject private var monitor = WindowCaptureMonitor.shared

    var body: some View {
        InspectorSection("WINDOW CAPTURE") {
            Picker("Window", selection: store.configBinding("windowID")) {
                Text("Choose a window…").tag("")
                ForEach(monitor.windows) { window in Text(window.title).tag(window.id) }
            }
            .labelsHidden()
            .frame(maxWidth: .infinity)
            Button("Refresh Window List") { monitor.refreshWindows() }.buttonStyle(.bordered)
            Text(monitor.status).font(.system(size: 10)).foregroundStyle(.secondary)
            Button("Open Screen Recording Settings") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") { NSWorkspace.shared.open(url) }
            }
            .buttonStyle(.borderless)
            Text("macOS controls which windows can be captured. The first permission change may require reopening SubScreen Studio.")
                .font(.system(size: 10)).foregroundStyle(.secondary)
        }
        .onAppear { monitor.refreshWindows() }
    }
}

private struct NewsFeedInspector: View {
    @EnvironmentObject private var store: StudioStore

    private let presets: [(String, String)] = [
        ("CNN World", "https://rss.cnn.com/rss/edition_world.rss"),
        ("Yahoo News", "https://news.yahoo.com/rss/"),
        ("TechCrunch", "https://techcrunch.com/feed/"),
        ("The Verge", "https://www.theverge.com/rss/index.xml")
    ]

    var body: some View {
        InspectorSection("NEWS FEED") {
            Picker("Source", selection: store.configBinding("source", fallback: "TechCrunch")) {
                ForEach(presets, id: \.0) { name, _ in Text(name).tag(name) }
                Text("Custom RSS").tag("Custom RSS")
            }
            .onChange(of: store.selectedLayer?.configValue("source")) { _, source in
                guard let source, let preset = presets.first(where: { $0.0 == source }) else { return }
                store.configBinding("url").wrappedValue = preset.1
                NewsFeedMonitor.shared.refresh(preset.1)
            }
            TextField("RSS feed URL", text: store.configBinding("url"))
                .textFieldStyle(.roundedBorder)
            Button("Refresh Headlines") {
                NewsFeedMonitor.shared.refresh(store.selectedLayer?.configValue("url") ?? "")
            }
            .buttonStyle(.borderedProminent)
            Text("Choose a preset or paste any public RSS/Atom feed URL.")
                .font(.system(size: 10)).foregroundStyle(.secondary)
        }
    }
}

struct InspectorSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct HexColorField: View {
    @Binding var value: String
    @State private var color = Color.black

    var body: some View {
        HStack(spacing: 6) {
            ColorPicker("", selection: Binding(
                get: { Color(studioHex: value) },
                set: { newValue in
                    if let ns = NSColor(newValue).usingColorSpace(.deviceRGB) {
                        value = String(format: "#%02X%02X%02X", Int(ns.redComponent * 255), Int(ns.greenComponent * 255), Int(ns.blueComponent * 255))
                    }
                }
            ), supportsOpacity: false)
            .labelsHidden()
            TextField("#000000", text: $value)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 10, design: .monospaced))
                .frame(width: 78)
        }
    }
}
