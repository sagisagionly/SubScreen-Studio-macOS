import AppKit
import SwiftUI

struct EditorCanvas: View {
    @EnvironmentObject private var store: StudioStore
    @Environment(\.colorScheme) private var colorScheme
    @State private var magnificationStart: Double?
    @FocusState private var canvasHasFocus: Bool

    var body: some View {
        GeometryReader { proxy in
            let fittedScale = max(0.1, min(
                (proxy.size.width - 48) / store.canvasSize.width,
                (proxy.size.height - 48) / store.canvasSize.height,
                1.2
            ))
            let scale = store.fitPreview ? fittedScale : store.zoom

            ZStack {
                StudioTheme.workspace(colorScheme)
                if let scene = store.currentScene {
                    if store.fitPreview {
                        // The normal fitted canvas does not need scrolling.
                        // Removing the enclosing scroll gesture makes a layer
                        // follow the pointer immediately, like a native window.
                        canvas(scene: scene, scale: scale)
                            .padding(24)
                    } else {
                        ScrollView([.horizontal, .vertical]) {
                            canvas(scene: scene, scale: scale)
                                .padding(24)
                        }
                        .frame(minWidth: proxy.size.width, minHeight: proxy.size.height)
                    }
                }
            }
            .onAppear { store.effectivePreviewScale = scale }
            .onChange(of: scale) { _, value in store.effectivePreviewScale = value }
        }
    }

    private func canvas(scene: StudioScene, scale: Double) -> some View {
        ZStack(alignment: .topLeading) {
            Color(studioHex: scene.backgroundHex)
            if store.showGrid { CanvasGrid(scale: scale) }
            ForEach(scene.layers) { layer in
                if !layer.isHidden {
                    InteractiveLayer(
                        layer: layer,
                        scale: scale,
                        onSelect: {
                            store.selectLayer(layer.id)
                            canvasHasFocus = true
                        }
                    )
                }
            }
            ForEach(store.verticalSnapGuides, id: \.self) { x in
                Rectangle().fill(Color.yellow.opacity(0.95)).frame(width: 1, height: store.canvasSize.height * scale).offset(x: x * scale)
            }
            ForEach(store.horizontalSnapGuides, id: \.self) { y in
                Rectangle().fill(Color.yellow.opacity(0.95)).frame(width: store.canvasSize.width * scale, height: 1).offset(y: y * scale)
            }
        }
        .frame(width: store.canvasSize.width * scale, height: store.canvasSize.height * scale)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(StudioTheme.divider(colorScheme)))
        .shadow(color: .black.opacity(colorScheme == .dark ? 0.55 : 0.20), radius: 24, y: 12)
        .dropDestination(for: URL.self) { urls, location in
            store.importFiles(urls, at: CGPoint(x: location.x / scale, y: location.y / scale)); return true
        }
        .onTapGesture { store.selectedLayerID = nil; store.inspectorTab = 0 }
        .coordinateSpace(name: "studioCanvas")
        .simultaneousGesture(previewMagnificationGesture(currentScale: scale))
        .focusable()
        .focused($canvasHasFocus)
        .onMoveCommand { direction in nudge(direction) }
    }

    private func previewMagnificationGesture(currentScale: Double) -> some Gesture {
        MagnificationGesture()
            .onChanged { value in
                if magnificationStart == nil {
                    magnificationStart = currentScale
                    store.fitPreview = false
                }
                store.zoom = min(max((magnificationStart ?? currentScale) * value, 0.15), 2.0)
            }
            .onEnded { _ in magnificationStart = nil }
    }

    private func nudge(_ direction: MoveCommandDirection) {
        let step: CGFloat = NSEvent.modifierFlags.contains(.shift) ? 10 : 1
        switch direction {
        case .left: store.nudgeSelected(dx: -step, dy: 0)
        case .right: store.nudgeSelected(dx: step, dy: 0)
        case .up: store.nudgeSelected(dx: 0, dy: -step)
        case .down: store.nudgeSelected(dx: 0, dy: step)
        @unknown default: break
        }
    }
}

struct CanvasGrid: View {
    let scale: Double
    var body: some View {
        Canvas { context, size in
            var path = Path(); let step = max(6, 48 * scale)
            stride(from: 0.0, through: size.width, by: step).forEach { x in path.move(to: CGPoint(x: x, y: 0)); path.addLine(to: CGPoint(x: x, y: size.height)) }
            stride(from: 0.0, through: size.height, by: step).forEach { y in path.move(to: CGPoint(x: 0, y: y)); path.addLine(to: CGPoint(x: size.width, y: y)) }
            context.stroke(path, with: .color(.white.opacity(0.05)), lineWidth: 0.5)
        }.allowsHitTesting(false)
    }
}

private enum ResizeHandle: CaseIterable {
    case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left
    var cursor: NSCursor {
        switch self {
        case .left, .right: .resizeLeftRight
        case .top, .bottom: .resizeUpDown
        case .topLeft, .bottomRight, .topRight, .bottomLeft: .crosshair
        }
    }
}

struct InteractiveLayer: View {
    @EnvironmentObject private var store: StudioStore
    let layer: StudioLayer
    let scale: Double
    let onSelect: () -> Void
    @State private var interactionStart: CGRect?
    @State private var activeResizeHandle: ResizeHandle?
    @State private var transientFrame: CGRect?
    @State private var selectAfterInteraction = false
    @State private var editingText = false
    @State private var textDraft = ""
    @FocusState private var textEditorFocused: Bool

    private var selected: Bool { store.selectedLayerID == layer.id }
    private var displayFrame: CGRect { transientFrame ?? layer.frame.rect }

    var body: some View {
        TransformedWidgetContent(layer: layer, frame: displayFrame, previewScale: scale)
            // This is the actual widget mask. Selection chrome is deliberately
            // rectangular so changing radius cannot look like an outer frame.
            .clipShape(RoundedRectangle(cornerRadius: layer.cornerRadius * scale, style: .continuous))
            .opacity(layer.opacity)
            .overlay {
                if selected {
                    Rectangle()
                        .stroke(Color.accentColor, lineWidth: 1.5)
                        .allowsHitTesting(false)
                }
            }
            .overlay { if selected && !layer.isLocked { resizeHandles } }
            .frame(width: displayFrame.width * scale, height: displayFrame.height * scale)
            // Attach before `position` so DragGesture.startLocation is local to
            // the layer and corner/edge hit testing remains exact at any zoom.
            // Claim the drag before the surrounding ScrollView. Letting both
            // gestures compete was the source of the sticky, delayed feel.
            .highPriorityGesture(transformGesture)
            .position(x: displayFrame.midX * scale, y: displayFrame.midY * scale)
            .contentShape(Rectangle())
            .transaction { $0.animation = nil }
            .onTapGesture { onSelect() }
            .onTapGesture(count: 2) {
                guard layer.kind == .text else { return }
                onSelect()
                textDraft = layer.text
                editingText = true
                textEditorFocused = true
            }
            .overlay {
                if editingText && layer.kind == .text {
                    TextEditor(text: $textDraft)
                        .font(editorFont)
                        .foregroundStyle(Color(studioHex: layer.foregroundHex))
                        .scrollContentBackground(.hidden)
                        .padding(12 * scale)
                        .background(Color(studioHex: layer.backgroundHex).opacity(0.96))
                        .focused($textEditorFocused)
                        .onSubmit { finishTextEditing() }
                        .onChange(of: textEditorFocused) { _, focused in if !focused { finishTextEditing() } }
                }
            }
            .contextMenu {
                Button("Bring Forward") { store.moveLayerInStack(layer.id, delta: 1) }
                Button("Send Backward") { store.moveLayerInStack(layer.id, delta: -1) }
                Divider()
                Button("Delete", role: .destructive) { store.selectedLayerID = layer.id; store.deleteSelectedLayer() }
            }
    }

    private var editorFont: Font {
        let size = max(10, layer.fontSize * scale * layer.contentScale(for: displayFrame))
        if let name = layer.fontName, !name.isEmpty { return .custom(name, size: size) }
        return .system(size: size, weight: .semibold, design: .rounded)
    }

    /// Movement and resizing share one gesture. The pointer-down location is
    /// classified once, so a body drag can never become a resize midway through
    /// the interaction (and vice versa).
    private var transformGesture: some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                guard !layer.isLocked else { return }
                if interactionStart == nil {
                    let wasSelected = selected
                    selectAfterInteraction = !wasSelected
                    interactionStart = layer.frame.rect
                    transientFrame = layer.frame.rect
                    if wasSelected {
                        activeResizeHandle = resizeHandle(
                            at: value.startLocation,
                            in: CGSize(width: layer.frame.width * scale, height: layer.frame.height * scale)
                        )
                    }
                    store.beginLayerInteraction()
                }
                guard let start = interactionStart else { return }
                let snapping = !NSEvent.modifierFlags.contains(.control)
                if let handle = activeResizeHandle {
                    let freeResize = NSEvent.modifierFlags.contains(.shift)
                    let fromCenter = NSEvent.modifierFlags.contains(.option)
                    let proposed = resizedFrame(
                        start,
                        handle: handle,
                        dx: value.translation.width / scale,
                        dy: value.translation.height / scale,
                        keepRatio: store.preserveAspectRatio && !freeResize,
                        fromCenter: fromCenter
                    )
                    transientFrame = store.previewResizeFrame(proposed, excluding: layer.id, snap: snapping)
                } else {
                    var proposed = start
                    proposed.origin.x += value.translation.width / scale
                    proposed.origin.y += value.translation.height / scale
                    transientFrame = store.previewMoveFrame(proposed, excluding: layer.id, snap: snapping)
                }
            }
            .onEnded { _ in
                guard interactionStart != nil else { return }
                if let transientFrame { store.commitLayerFrame(layer.id, frame: transientFrame) }
                if selectAfterInteraction { onSelect() }
                transientFrame = nil
                interactionStart = nil
                activeResizeHandle = nil
                selectAfterInteraction = false
                store.endLayerInteraction()
            }
    }

    private func resizeHandle(at point: CGPoint, in size: CGSize) -> ResizeHandle? {
        let tolerance: CGFloat = 18
        return ResizeHandle.allCases
            .map { ($0, hypot(handlePosition($0, in: size, inset: 7).x - point.x,
                             handlePosition($0, in: size, inset: 7).y - point.y)) }
            .filter { $0.1 <= tolerance }
            .min { $0.1 < $1.1 }?.0
    }

    private func finishTextEditing() {
        guard editingText else { return }
        editingText = false
        store.updateLayer(layer.id) { $0.text = textDraft }
    }

    private var resizeHandles: some View {
        GeometryReader { proxy in
            ForEach(ResizeHandle.allCases, id: \.self) { handle in
                RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                    .fill(.white)
                    .overlay(RoundedRectangle(cornerRadius: 2.5, style: .continuous).stroke(Color.accentColor, lineWidth: 1.5))
                    .frame(width: 11, height: 11)
                    .position(handlePosition(handle, in: proxy.size, inset: 7))
                    .onHover { inside in if inside { handle.cursor.push() } else { NSCursor.pop() } }
            }
        }
        .allowsHitTesting(false)
    }

    private func resizedFrame(_ start: CGRect, handle: ResizeHandle, dx: Double, dy: Double, keepRatio: Bool, fromCenter: Bool) -> CGRect {
        var left = start.minX, right = start.maxX, top = start.minY, bottom = start.maxY
        let movesLeft = [.topLeft, .left, .bottomLeft].contains(handle)
        let movesRight = [.topRight, .right, .bottomRight].contains(handle)
        let movesTop = [.topLeft, .top, .topRight].contains(handle)
        let movesBottom = [.bottomLeft, .bottom, .bottomRight].contains(handle)
        if movesLeft { left += dx; if fromCenter { right -= dx } }
        if movesRight { right += dx; if fromCenter { left -= dx } }
        if movesTop { top += dy; if fromCenter { bottom -= dy } }
        if movesBottom { bottom += dy; if fromCenter { top -= dy } }
        var width = max(24, right - left), height = max(24, bottom - top)
        if keepRatio && (movesLeft || movesRight) && (movesTop || movesBottom) {
            let ratio = start.width / max(start.height, 1)
            if abs(dx) > abs(dy) { height = width / ratio } else { width = height * ratio }
            if movesLeft { left = right - width } else { right = left + width }
            if movesTop { top = bottom - height } else { bottom = top + height }
        }
        if right - left < 24 { if movesLeft { left = right - 24 } else { right = left + 24 } }
        if bottom - top < 24 { if movesTop { top = bottom - 24 } else { bottom = top + 24 } }
        return CGRect(x: left, y: top, width: right - left, height: bottom - top)
    }

    private func handlePosition(_ handle: ResizeHandle, in size: CGSize, inset: CGFloat) -> CGPoint {
        switch handle {
        case .topLeft: CGPoint(x: inset, y: inset)
        case .top: CGPoint(x: size.width / 2, y: inset)
        case .topRight: CGPoint(x: size.width - inset, y: inset)
        case .right: CGPoint(x: size.width - inset, y: size.height / 2)
        case .bottomRight: CGPoint(x: size.width - inset, y: size.height - inset)
        case .bottom: CGPoint(x: size.width / 2, y: size.height - inset)
        case .bottomLeft: CGPoint(x: inset, y: size.height - inset)
        case .left: CGPoint(x: inset, y: size.height / 2)
        }
    }
}
