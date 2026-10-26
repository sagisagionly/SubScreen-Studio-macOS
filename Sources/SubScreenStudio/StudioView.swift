import SwiftUI

struct StudioView: View {
    @EnvironmentObject private var store: StudioStore
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("studioAppearance") private var appearance = "system"

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider().opacity(0.35)
            HSplitView {
                SceneSidebar()
                    .frame(minWidth: 170, idealWidth: 224, maxWidth: 340)
                VStack(spacing: 0) {
                    CanvasToolbar()
                    VSplitView {
                        EditorCanvas()
                            .frame(minHeight: 260)
                        SourcesBar()
                            .frame(minHeight: 100, idealHeight: 154, maxHeight: 320)
                    }
                }
                .frame(minWidth: 520)
                InspectorView()
                    .frame(minWidth: 250, idealWidth: 302, maxWidth: 430)
            }
        }
        .background(StudioTheme.chrome(colorScheme))
        .preferredColorScheme(preferredColorScheme)
        .overlay(alignment: .top) { AirPodsConnectionOverlay() }
        .overlay(alignment: .top) { IPhoneConnectionOverlay() }
        .onDeleteCommand { store.deleteSelectedLayer() }
    }

    private var preferredColorScheme: ColorScheme? {
        switch appearance {
        case "light": .light
        case "dark": .dark
        default: nil
        }
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            Image(systemName: "rectangle.3.group.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(.blue.gradient, in: RoundedRectangle(cornerRadius: 9))
            Text("SubScreen Studio")
                .font(.system(size: 14, weight: .semibold))
            Spacer()
            Menu {
                Picker("Appearance", selection: $appearance) {
                    Label("System", systemImage: "circle.lefthalf.filled").tag("system")
                    Label("Light", systemImage: "sun.max.fill").tag("light")
                    Label("Dark", systemImage: "moon.fill").tag("dark")
                }
            } label: {
                Image(systemName: appearance == "light" ? "sun.max.fill" : appearance == "dark" ? "moon.fill" : "circle.lefthalf.filled")
            }
            .menuStyle(.borderlessButton)
            .help("Appearance")
            ForEach(StudioDisplayProfile.allCases) { profile in
                displayStatus(profile)
            }
            Menu {
                Section("Go Live") {
                    Button("D92", systemImage: "rectangle.wide") { store.startLive(.d92) }
                        .disabled(store.isDisplayLive(.d92))
                    Button("2.88-inch", systemImage: "square") { store.startLive(.dq288) }
                        .disabled(store.isDisplayLive(.dq288))
                    Button("Both Displays", systemImage: "rectangle.2.swap") { store.startBothDisplays() }
                        .disabled(store.isDisplayLive(.d92) && store.isDisplayLive(.dq288))
                }
                Section("Stop") {
                    Button("Stop D92", systemImage: "stop.circle") { store.stopLive(.d92) }
                        .disabled(!store.isDisplayLive(.d92))
                    Button("Stop 2.88-inch", systemImage: "stop.circle") { store.stopLive(.dq288) }
                        .disabled(!store.isDisplayLive(.dq288))
                    Button("Stop All", systemImage: "stop.fill", role: .destructive) { store.stopAllDisplays() }
                        .disabled(!store.isLive)
                }
            } label: {
                Label(store.isLive ? "Live Controls" : "Go Live", systemImage: store.isLive ? "dot.radiowaves.left.and.right" : "play.fill")
                    .frame(width: 108)
            }
            .buttonStyle(.borderedProminent)
            .tint(store.isLive ? .green : .blue)
            .fixedSize()
        }
        .padding(.horizontal, 14)
        .frame(height: 56)
        .background(.ultraThinMaterial)
    }

    private func displayStatus(_ profile: StudioDisplayProfile) -> some View {
        let live = store.isDisplayLive(profile)
        let status = store.status(for: profile)
        return Button {
            if live { store.stopLive(profile) }
            else { store.startLive(profile) }
        } label: {
            HStack(spacing: 5) {
                Circle()
                    .fill(status == "Live" ? Color.green : live ? Color.orange : Color.secondary.opacity(0.45))
                    .frame(width: 7, height: 7)
                VStack(alignment: .leading, spacing: 0) {
                    Text(profile.shortTitle)
                        .font(.system(size: 10, weight: .semibold))
                    Text(status)
                        .font(.system(size: 8))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if live {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 34)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(live ? "Stop \(profile.shortTitle)" : "Go live on \(profile.shortTitle)")
    }
}

private struct IPhoneConnectionOverlay: View {
    @ObservedObject private var monitor = IPhoneConnectionMonitor.shared
    @State private var visible = false

    var body: some View {
        if visible, let name = monitor.connectedName {
            HStack(spacing: 14) {
                Image(systemName: "iphone")
                    .font(.system(size: 29, weight: .light))
                    .symbolEffect(.bounce, value: monitor.connectionSequence)
                VStack(alignment: .leading, spacing: 2) {
                    Text(name).font(.system(size: 13, weight: .semibold))
                    Text("Connected to this Mac").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            }
            .padding(.horizontal, 18)
            .frame(height: 64)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
            .overlay(RoundedRectangle(cornerRadius: 20).stroke(.primary.opacity(0.1)))
            .shadow(color: .black.opacity(0.18), radius: 18, y: 8)
            .padding(.top, 12)
            .transition(.move(edge: .top).combined(with: .opacity))
            .zIndex(101)
        }
        EmptyView()
            .onChange(of: monitor.connectionSequence) { _, sequence in
                guard sequence > 0, monitor.connectedName != nil else { return }
                withAnimation(.spring(response: 0.45, dampingFraction: 0.82)) { visible = true }
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(5))
                    guard monitor.connectionSequence == sequence else { return }
                    withAnimation(.easeOut(duration: 0.25)) { visible = false }
                }
            }
    }
}

private struct AirPodsConnectionOverlay: View {
    @ObservedObject private var monitor = AirPodsMonitor.shared
    @State private var visible = false

    var body: some View {
        if visible, let name = monitor.connectedName {
            HStack(spacing: 14) {
                Image(systemName: "airpodspro")
                    .font(.system(size: 30, weight: .light))
                    .symbolEffect(.bounce, value: monitor.connectionSequence)
                VStack(alignment: .leading, spacing: 2) {
                    Text(name).font(.system(size: 13, weight: .semibold))
                    Text("Connected").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            }
            .padding(.horizontal, 18)
            .frame(height: 64)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
            .overlay(RoundedRectangle(cornerRadius: 20).stroke(.primary.opacity(0.1)))
            .shadow(color: .black.opacity(0.18), radius: 18, y: 8)
            .padding(.top, 12)
            .transition(.move(edge: .top).combined(with: .opacity))
            .zIndex(100)
        }
        EmptyView()
            .onChange(of: monitor.connectionSequence) { _, sequence in
                guard sequence > 0, monitor.connectedName != nil else { return }
                withAnimation(.spring(response: 0.45, dampingFraction: 0.82)) { visible = true }
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(5))
                    guard monitor.connectionSequence == sequence else { return }
                    withAnimation(.easeOut(duration: 0.25)) { visible = false }
                }
            }
    }
}

struct SceneSidebar: View {
    @EnvironmentObject private var store: StudioStore
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("SCENES")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button { store.addScene() } label: { Image(systemName: "plus") }
                    .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .frame(height: 42)

            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(store.project.scenes) { scene in
                        SceneRow(scene: scene, selected: scene.id == store.selectedSceneID)
                            .onTapGesture { store.selectScene(scene.id) }
                    }
                }
                .padding(.horizontal, 10)
            }

            Divider().opacity(0.35)
            VStack(spacing: 6) {
                sidebarButton("Duplicate Scene", "plus.square.on.square") { store.duplicateCurrentScene() }
                sidebarButton("Delete Scene", "trash") { store.deleteCurrentScene() }
            }
            .padding(10)
        }
        .background(StudioTheme.panel(colorScheme))
    }

    private func sidebarButton(_ title: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: 12, weight: .medium))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 9)
                .frame(height: 30)
        }
        .buttonStyle(.plain)
        .background(StudioTheme.raised(colorScheme), in: RoundedRectangle(cornerRadius: 7))
    }
}

struct SceneRow: View {
    let scene: StudioScene
    let selected: Bool

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 7)
                    .fill(Color(studioHex: scene.backgroundHex))
                HStack(spacing: 2) {
                    ForEach(scene.layers.prefix(3)) { layer in
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color(studioHex: layer.backgroundHex))
                            .frame(width: 10, height: 18)
                    }
                }
            }
            .frame(width: 58, height: 30)
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(.primary.opacity(0.12)))
            VStack(alignment: .leading, spacing: 2) {
                Text(scene.name).font(.system(size: 12, weight: .medium))
                Text("\(scene.resolvedOutputDisplay.shortTitle) • \(scene.layers.count) sources")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(8)
        .background(selected ? Color.blue.opacity(0.22) : Color.clear, in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(selected ? Color.blue.opacity(0.7) : .clear))
        .contentShape(Rectangle())
    }
}

struct CanvasToolbar: View {
    @EnvironmentObject private var store: StudioStore
    @Environment(\.colorScheme) private var colorScheme
    @State private var showingLibrary = false

    var body: some View {
        HStack(spacing: 6) {
            Button { showingLibrary = true } label: {
                Label("Add Widget", systemImage: "plus")
            }
            .buttonStyle(.borderless)
            Button { store.chooseMediaFiles() } label: {
                Label("Import Media", systemImage: "photo.on.rectangle.angled")
            }
            .buttonStyle(.borderless)
            .help("Add images or videos")
            Divider().frame(height: 18)
            Button { store.showGrid.toggle() } label: {
                Image(systemName: "grid")
                    .foregroundStyle(store.showGrid ? Color.blue : Color.secondary)
            }
            .buttonStyle(.plain)
            .help("Toggle grid")
            Button { store.snapToGrid.toggle() } label: {
                Image(systemName: "lines.measurement.horizontal")
                    .foregroundStyle(store.snapToGrid ? Color.blue : Color.secondary)
            }
            .buttonStyle(.plain)
            .help("Magnetic snapping")
            Button { store.preserveAspectRatio.toggle() } label: {
                Image(systemName: store.preserveAspectRatio ? "aspectratio.fill" : "aspectratio")
                    .foregroundStyle(store.preserveAspectRatio ? Color.blue : Color.secondary)
            }
            .buttonStyle(.plain)
                .help("Lock corner aspect ratio. Side handles always stretch one axis.")
            Spacer()
            Text(store.currentDisplayProfile.resolutionText)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
            Button("Fit") { store.fitPreview = true }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(store.fitPreview ? .blue : nil)
            TextField("Zoom", value: zoomPercent, format: .number.precision(.fractionLength(0)))
                .textFieldStyle(.roundedBorder)
                .frame(width: 52)
                .multilineTextAlignment(.trailing)
            Text("%")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .frame(height: 42)
        .background(StudioTheme.chrome(colorScheme))
        .sheet(isPresented: $showingLibrary) {
            WidgetLibraryView().environmentObject(store)
        }
    }

    private var zoomPercent: Binding<Double> {
        Binding(
            get: { (store.fitPreview ? store.effectivePreviewScale : store.zoom) * 100 },
            set: {
                store.fitPreview = false
                store.zoom = min(max($0 / 100, 0.15), 2.0)
            }
        )
    }
}

struct SourcesBar: View {
    @EnvironmentObject private var store: StudioStore
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 0) {
            Divider().opacity(0.35)
            HStack {
                Label("LAYERS", systemImage: "square.3.layers.3d")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if let id = store.selectedLayerID {
                    Button { store.moveLayerInStack(id, delta: 1) } label: { Image(systemName: "arrow.up") }
                        .buttonStyle(.plain).help("Move layer forward")
                    Button { store.moveLayerInStack(id, delta: -1) } label: { Image(systemName: "arrow.down") }
                        .buttonStyle(.plain).help("Move layer backward")
                }
                Button { store.deleteSelectedLayer() } label: { Image(systemName: "trash") }
                    .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .frame(height: 34)
            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(Array((store.currentScene?.layers ?? []).reversed())) { layer in
                        HStack(spacing: 8) {
                            Image(systemName: layer.kind.symbol)
                                .foregroundStyle(store.selectedLayerID == layer.id ? .blue : .secondary)
                                .frame(width: 18)
                            Text(layer.name)
                                .font(.system(size: 11, weight: .medium))
                                .lineLimit(1)
                            Spacer()
                            Button { store.toggleLayerVisibility(layer.id) } label: {
                                Image(systemName: layer.isHidden ? "eye.slash" : "eye")
                            }
                            .buttonStyle(.plain).help(layer.isHidden ? "Show layer" : "Hide layer")
                            Button { store.toggleLayerLock(layer.id) } label: {
                                Image(systemName: layer.isLocked ? "lock.fill" : "lock.open")
                            }
                            .buttonStyle(.plain).help(layer.isLocked ? "Unlock layer" : "Lock layer")
                        }
                        .padding(.horizontal, 10)
                        .frame(height: 28)
                        .background(store.selectedLayerID == layer.id ? Color.accentColor.opacity(colorScheme == .dark ? 0.28 : 0.14) : StudioTheme.raised(colorScheme), in: RoundedRectangle(cornerRadius: 7))
                        .overlay(RoundedRectangle(cornerRadius: 7).stroke(store.selectedLayerID == layer.id ? Color.accentColor.opacity(0.65) : .clear))
                        .contentShape(Rectangle())
                        .onTapGesture { store.selectLayer(layer.id) }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 10)
            }
        }
        .background(StudioTheme.panel(colorScheme))
    }
}
