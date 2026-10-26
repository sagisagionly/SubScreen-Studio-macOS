import SwiftUI

struct WidgetLibraryView: View {
    @EnvironmentObject private var store: StudioStore
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @State private var selectedPreset: WidgetSizePreset = .medium

    private var filtered: [LayerKind] {
        guard !search.isEmpty else { return LayerKind.allCases }
        return LayerKind.allCases.filter {
            $0.title.localizedCaseInsensitiveContains(search) ||
            $0.summary.localizedCaseInsensitiveContains(search) ||
            $0.category.rawValue.localizedCaseInsensitiveContains(search)
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 22) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Choose a size")
                            .font(.headline)
                        HStack(spacing: 8) {
                            ForEach(WidgetSizePreset.allCases) { preset in
                                Button {
                                    selectedPreset = preset
                                } label: {
                                    VStack(spacing: 7) {
                                        Image(systemName: preset.symbol)
                                            .font(.system(size: 19, weight: .medium))
                                        Text(preset.title)
                                            .font(.system(size: 11, weight: .semibold))
                                    }
                                    .foregroundStyle(selectedPreset == preset ? Color.white : Color.primary)
                                    .frame(maxWidth: .infinity, minHeight: 58)
                                    .background(selectedPreset == preset ? Color.accentColor : Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        Text("Like iPhone widgets, each size uses a layout designed for that space. You can still resize freely on the canvas.")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }

                    ForEach(WidgetCategory.allCases) { category in
                        let widgets = filtered.filter { $0.category == category }
                        if !widgets.isEmpty {
                            VStack(alignment: .leading, spacing: 10) {
                                Text(category.rawValue)
                                    .font(.headline)
                                LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), spacing: 10)], spacing: 10) {
                                    ForEach(widgets) { kind in
                                        WidgetLibraryCard(kind: kind) {
                                            if kind == .image || kind == .video {
                                                dismiss()
                                                Task { @MainActor in store.chooseMediaFiles() }
                                            } else {
                                                store.addLayer(kind, preset: selectedPreset)
                                                dismiss()
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(20)
            }
            .searchable(text: $search, prompt: "Search widgets")
            .navigationTitle("Widget Gallery")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .frame(minWidth: 760, minHeight: 600)
    }
}

private struct WidgetLibraryCard: View {
    let kind: LayerKind
    let add: () -> Void

    var body: some View {
        Button(action: add) {
            HStack(spacing: 13) {
                Image(systemName: kind.symbol)
                    .font(.system(size: 22, weight: .medium))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.blue)
                    .frame(width: 38, height: 38)
                    .background(.blue.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 5) {
                        Text(kind.title).font(.system(size: 13, weight: .semibold))
                        if kind.worksLocally {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(.green)
                        }
                    }
                    Text(kind.summary)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
                Image(systemName: "plus.circle.fill").foregroundStyle(.blue)
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 70, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 13))
            .overlay(RoundedRectangle(cornerRadius: 13).stroke(.primary.opacity(0.08)))
        }
        .buttonStyle(.plain)
    }
}
