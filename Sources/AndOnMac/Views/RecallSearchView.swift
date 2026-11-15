import SwiftUI
import AppKit

/// Spotlight-style floating search view ("Recall") backed by `ScreenMemoryDatabase` FTS5.
public struct RecallSearchView: View {
    @ObservedObject var appState: AppState
    @ObservedObject private var snapshotter = ScreenMemorySnapshotter.shared
    public let onDismiss: () -> Void

    @State private var query: String = ""
    @State private var results: [ScreenMemorySearchResult] = []
    @State private var selectedIndex: Int = 0
    @State private var copiedId: Int64? = nil
    @State private var searchWorkItem: DispatchWorkItem? = nil
    @FocusState private var isSearchFocused: Bool

    public init(appState: AppState, onDismiss: @escaping () -> Void) {
        self.appState = appState
        self.onDismiss = onDismiss
    }

    private var lang: AppLanguage { appState.lang }

    public var body: some View {
        VStack(spacing: 0) {
            // Spotlight Search Bar
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundColor(.cyan)

                TextField(
                    L10n.tr("Поиск по истории экрана (Recall)...", "Search Android screen memory...", lang: lang),
                    text: $query
                )
                .textFieldStyle(.plain)
                .font(.system(size: 17, weight: .regular))
                .focused($isSearchFocused)
                .onSubmit {
                    copySelectedResult()
                }

                if !query.isEmpty {
                    Button {
                        query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }

                Divider()
                    .frame(height: 18)

                Toggle(isOn: $appState.screenMemoryEnabled) {
                    Text(L10n.tr("Индексация", "Capture", lang: lang))
                        .font(.system(size: 11, weight: .medium))
                }
                .toggleStyle(.switch)
                .controlSize(.mini)
                .onChange(of: appState.screenMemoryEnabled) { _, _ in
                    appState.syncScreenMemoryState()
                }

                Button {
                    onDismiss()
                } label: {
                    Text("ESC")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Color.primary.opacity(0.08))
                        .cornerRadius(5)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 13)

            Divider()

            // Results or Empty State
            if results.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: appState.screenMemoryEnabled ? "clock.arrow.circlepath" : "brain.head.profile")
                        .font(.system(size: 30))
                        .foregroundColor(.secondary.opacity(0.65))

                    if !appState.screenMemoryEnabled && snapshotter.indexedCount == 0 {
                        Text(L10n.tr("Screen Memory выключена (Opt-In)", "Screen Memory is Off (Opt-In)", lang: lang))
                            .font(.headline)
                        Text(L10n.tr(
                            "Включите переключатель «Индексация» выше, чтобы локально индексировать экран через Apple Vision OCR каждые 10 секунд.",
                            "Enable 'Capture' above to locally index changed Android screens on Apple Silicon every 10 seconds.",
                            lang: lang
                        ))
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 380)
                    } else {
                        Text(query.isEmpty
                             ? L10n.tr("Пока нет сохранённых снимков", "No Screen Snapshots Yet", lang: lang)
                             : L10n.tr("Ничего не найдено для «\(query)»", "No matches for '\(query)'", lang: lang))
                            .font(.subheadline.weight(.medium))
                            .foregroundColor(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 6) {
                            ForEach(Array(results.enumerated()), id: \.element.id) { index, item in
                                RecallResultRow(
                                    result: item,
                                    isSelected: index == selectedIndex,
                                    isCopied: copiedId == item.id,
                                    lang: lang,
                                    onSelect: { selectedIndex = index },
                                    onCopy: { copyResult(item) }
                                )
                                .id(item.id)
                            }
                        }
                        .padding(10)
                    }
                    .onChange(of: selectedIndex) { _, newIdx in
                        if results.indices.contains(newIdx) {
                            withAnimation(.easeOut(duration: 0.12)) {
                                proxy.scrollTo(results[newIdx].id, anchor: .center)
                            }
                        }
                    }
                }
            }

            Divider()

            // Footer Stats & Retention Controls
            HStack(spacing: 10) {
                Text("\(snapshotter.indexedCount) " + L10n.tr("снимков", "snapshots", lang: lang) + " · " + formattedBytes(snapshotter.storageBytes))
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)

                Text("· 7d FTS5")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary.opacity(0.75))

                Spacer()

                if snapshotter.indexedCount > 0 {
                    Button(role: .destructive) {
                        snapshotter.clearAllMemory()
                        performSearch(query)
                    } label: {
                        Label(L10n.tr("Очистить историю", "Clear History", lang: lang), systemImage: "trash")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.borderless)
                    .foregroundColor(.red.opacity(0.85))
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
        .frame(width: 660, height: 460)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.white.opacity(0.18), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.35), radius: 28, y: 12)
        .onAppear {
            isSearchFocused = true
            performSearch(query)
            snapshotter.refreshStats()
        }
        .onChange(of: query) { _, newValue in
            scheduleDebouncedSearch(newValue)
        }
        .onKeyPress(.downArrow) {
            if !results.isEmpty {
                selectedIndex = min(results.count - 1, selectedIndex + 1)
            }
            return .handled
        }
        .onKeyPress(.upArrow) {
            if !results.isEmpty {
                selectedIndex = max(0, selectedIndex - 1)
            }
            return .handled
        }
    }

    private func scheduleDebouncedSearch(_ q: String) {
        searchWorkItem?.cancel()
        let work = DispatchWorkItem {
            performSearch(q)
        }
        searchWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.09, execute: work)
    }

    private func performSearch(_ q: String) {
        let hits = ScreenMemoryDatabase.shared.search(query: q, limit: 40)
        results = hits
        selectedIndex = 0
    }

    private func copySelectedResult() {
        guard results.indices.contains(selectedIndex) else { return }
        copyResult(results[selectedIndex])
    }

    private func copyResult(_ item: ScreenMemorySearchResult) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(item.extractedText, forType: .string)
        copiedId = item.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
            if copiedId == item.id {
                copiedId = nil
            }
        }
    }

    private func formattedBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

private struct RecallResultRow: View {
    let result: ScreenMemorySearchResult
    let isSelected: Bool
    let isCopied: Bool
    let lang: AppLanguage
    let onSelect: () -> Void
    let onCopy: () -> Void

    private static let timeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ThumbnailPreview(url: result.thumbnailURL)
                .frame(width: 58, height: 102)
                .cornerRadius(6)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.white.opacity(0.15), lineWidth: 0.5)
                )

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(result.appPackageName)
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundColor(.cyan)
                        .lineLimit(1)

                    Text("·")
                        .foregroundColor(.secondary)

                    Text(Self.timeFormatter.localizedString(for: result.timestamp, relativeTo: Date()))
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)

                    Spacer()

                    Button {
                        onCopy()
                    } label: {
                        Label(
                            isCopied ? L10n.tr("Скопировано", "Copied", lang: lang) : L10n.tr("Копировать", "Copy", lang: lang),
                            systemImage: isCopied ? "checkmark.circle.fill" : "doc.on.doc"
                        )
                        .font(.system(size: 11, weight: .medium))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                    .tint(isCopied ? .green : .accentColor)
                }

                highlightedText(result.highlightedSnippet)
                    .font(.system(size: 12))
                    .lineLimit(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(10)
        .background(isSelected ? Color.accentColor.opacity(0.16) : Color.primary.opacity(0.04))
        .cornerRadius(10)
        .contentShape(Rectangle())
        .onTapGesture {
            onSelect()
        }
    }

    private func highlightedText(_ snippet: String) -> Text {
        // Parse `«match»` markers emitted by SQLite FTS5 snippet()
        var output = Text("")
        var remaining = snippet[...]
        while let openRange = remaining.range(of: "«") {
            let prefix = String(remaining[..<openRange.lowerBound])
            if !prefix.isEmpty {
                output = output + Text(prefix).foregroundColor(.primary.opacity(0.85))
            }
            let afterOpen = remaining[openRange.upperBound...]
            if let closeRange = afterOpen.range(of: "»") {
                let match = String(afterOpen[..<closeRange.lowerBound])
                output = output + Text(match).bold().foregroundColor(.cyan)
                remaining = afterOpen[closeRange.upperBound...]
            } else {
                output = output + Text(String(remaining[openRange.lowerBound...])).foregroundColor(.primary.opacity(0.85))
                remaining = remaining[remaining.endIndex...]
            }
        }
        if !remaining.isEmpty {
            output = output + Text(String(remaining)).foregroundColor(.primary.opacity(0.85))
        }
        return output
    }
}

private struct ThumbnailPreview: View {
    let url: URL
    @State private var image: NSImage? = nil

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    Color.black.opacity(0.25)
                    Image(systemName: "photo")
                        .foregroundColor(.secondary.opacity(0.6))
                }
            }
        }
        .clipped()
        .onAppear {
            if image == nil {
                image = NSImage(contentsOf: url)
            }
        }
    }
}
