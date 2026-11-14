import SwiftUI
import AppKit

public struct PhotoTransferDrawerView: View {
    @ObservedObject var appState: AppState
    @State private var photos: [PhotoItem] = []
    @State private var selectedFilter: MediaFolderFilter = .all
    @State private var currentLimit: Int = 500
    @State private var isLoading: Bool = false
    @State private var statusNote: String? = nil

    public init(appState: AppState) {
        self.appState = appState
    }

    public var body: some View {
        let lang = appState.lang
        VStack(spacing: 0) {
            // Header
            HStack {
                HStack(spacing: 6) {
                    Image(systemName: "photo.stack")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(.blue)
                    Text(L10n.tr("Медиатека телефона", "Phone Gallery", lang: lang))
                        .font(.system(size: 13, weight: .bold))
                    if !photos.isEmpty {
                        Text("\(photos.count)")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.primary.opacity(0.08))
                            .cornerRadius(6)
                    }
                }
                Spacer()

                Button {
                    loadPhotos(resetLimit: false)
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .help(L10n.tr("Обновить", "Refresh", lang: lang))

                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        appState.showPhotoDrawer = false
                    }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help(L10n.tr("Закрыть", "Close", lang: lang))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
            .makeWindowDraggable()

            // Category Filter Bar
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(MediaFolderFilter.allCases) { filter in
                        Button {
                            selectedFilter = filter
                            loadPhotos(resetLimit: true)
                        } label: {
                            Text(filter.title(lang: lang))
                                .font(.system(size: 11, weight: selectedFilter == filter ? .semibold : .regular))
                                .padding(.horizontal, 9)
                                .padding(.vertical, 4)
                                .background(selectedFilter == filter ? Color.blue.opacity(0.22) : Color.primary.opacity(0.07))
                                .foregroundColor(selectedFilter == filter ? .blue : .primary)
                                .cornerRadius(8)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            }

            Divider()

            if isLoading && photos.isEmpty {
                VStack(spacing: 12) {
                    Spacer()
                    ProgressView()
                    Text(L10n.tr("Загрузка медиафайлов...", "Loading media...", lang: lang))
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
                .makeWindowDraggable()
            } else if photos.isEmpty {
                VStack(spacing: 12) {
                    Spacer()
                    Image(systemName: "photo.on.rectangle.angled")
                        .font(.system(size: 36))
                        .foregroundColor(.secondary.opacity(0.6))
                    Text(L10n.tr("Медиафайлы не найдены", "No media found", lang: lang))
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    Text(L10n.tr("Сделайте фото или выберите другую категорию", "Take a photo or choose another category", lang: lang))
                        .font(.caption2)
                        .foregroundColor(.secondary.opacity(0.8))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 16)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
                .makeWindowDraggable()
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 80), spacing: 8)], spacing: 8) {
                        ForEach(photos) { item in
                            PhotoThumbnailCell(item: item, serial: appState.selectedDevice?.id ?? "", lang: lang)
                        }
                    }
                    .padding(12)

                    if photos.count >= currentLimit {
                        Button {
                            currentLimit += 500
                            loadPhotos(resetLimit: false)
                        } label: {
                            HStack(spacing: 6) {
                                if isLoading {
                                    ProgressView()
                                        .scaleEffect(0.6)
                                }
                                Text(L10n.tr("Загрузить ещё (+500)", "Load more (+500)", lang: lang))
                                    .font(.caption.bold())
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                        }
                        .buttonStyle(.bordered)
                        .padding(.horizontal, 12)
                        .padding(.bottom, 12)
                    }
                }
            }

            Divider()

            // Bottom Action Bar: Send photos from Mac to Android
            HStack {
                Button {
                    pickAndSendPhotos()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "plus.circle.fill")
                        Text(L10n.tr("Перенести фото с Mac...", "Send from Mac...", lang: lang))
                    }
                    .font(.caption.bold())
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Spacer()

                if let note = statusNote {
                    Text(note)
                        .font(.caption2)
                        .foregroundColor(.green)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color.primary.opacity(0.03))
            .contentShape(Rectangle())
            .makeWindowDraggable()
        }
        .frame(width: 290)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(.ultraThinMaterial)
                .shadow(color: Color.black.opacity(0.3), radius: 15, x: -5, y: 5)
                .makeWindowDraggable()
        )
        .onAppear {
            loadPhotos(resetLimit: true)
        }
    }

    private func loadPhotos(resetLimit: Bool) {
        guard let device = appState.selectedDevice else { return }
        if resetLimit {
            currentLimit = 500
        }
        let limitToLoad = currentLimit
        let filterToLoad = selectedFilter
        isLoading = true
        Task {
            let items = await PhotoTransferService.shared.fetchRecentPhotos(serial: device.id, limit: limitToLoad, folder: filterToLoad)
            await MainActor.run {
                self.photos = items
                self.isLoading = false
            }
        }
    }

    private func pickAndSendPhotos() {
        guard let device = appState.selectedDevice else { return }
        let lang = appState.lang
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.image, .movie, .data]
        panel.prompt = L10n.tr("Отправить на телефон", "Send to Phone", lang: lang)

        if panel.runModal() == .OK {
            let urls = panel.urls
            Task {
                let res = await PhotoTransferService.shared.pushFiles(urls: urls, serial: device.id)
                await MainActor.run {
                    self.statusNote = res.message
                    if res.success {
                        loadPhotos(resetLimit: false)
                    }
                }
            }
        }
    }
}

// Single Photo Thumbnail with drag & drop and context menu support
private struct PhotoThumbnailCell: View {
    let item: PhotoItem
    let serial: String
    let lang: AppLanguage
    @State private var cachedURL: URL?
    @State private var thumbnailImage: NSImage?
    @State private var failedLoad: Bool = false

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            if let img = thumbnailImage {
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 80, height: 80)
                    .clipped()
                    .cornerRadius(8)
            } else if failedLoad {
                Rectangle()
                    .fill(Color.primary.opacity(0.08))
                    .frame(width: 80, height: 80)
                    .cornerRadius(8)
                    .overlay(
                        Image(systemName: item.isVideo ? "video.fill" : "photo")
                            .foregroundColor(.secondary)
                    )
            } else {
                Rectangle()
                    .fill(Color.primary.opacity(0.1))
                    .frame(width: 80, height: 80)
                    .cornerRadius(8)
                    .overlay(
                        ProgressView()
                            .scaleEffect(0.6)
                    )
            }

            if item.isVideo {
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(.white)
                    .padding(4)
                    .shadow(radius: 2)
            } else if item.isScreenshot {
                Image(systemName: "camera.viewfinder")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(.white)
                    .padding(3)
                    .background(Color.black.opacity(0.6))
                    .cornerRadius(4)
                    .padding(4)
            }
        }
        .frame(width: 80, height: 80)
        .contentShape(Rectangle())
        .help(item.name)
        .onAppear {
            ensureDownloaded()
        }
        .contextMenu {
            Button(L10n.tr("Открыть в Просмотре", "Open in Preview", lang: lang)) {
                openInPreview()
            }
            Button(L10n.tr("Сохранить на Mac...", "Save to Mac...", lang: lang)) {
                saveToMac()
            }
        }
        .onDrag {
            if let local = cachedURL {
                let provider = NSItemProvider(object: local as NSURL)
                let ext = local.pathExtension.lowercased()
                let uti = (ext == "png") ? "public.png" : (ext == "mp4" || ext == "mov" ? "public.mpeg-4" : "public.jpeg")
                if let data = try? Data(contentsOf: local) {
                    provider.registerDataRepresentation(forTypeIdentifier: uti, visibility: .all) { completion in
                        completion(data, nil)
                        return nil
                    }
                }
                return provider
            }
            return NSItemProvider()
        }
    }

    private func ensureDownloaded() {
        if let existing = item.localURL {
            self.cachedURL = existing
            Task {
                let thumb = await PhotoTransferService.shared.generateThumbnail(for: existing)
                await MainActor.run {
                    if let thumb {
                        self.thumbnailImage = thumb
                    } else {
                        self.failedLoad = true
                    }
                }
            }
            return
        }

        Task {
            if let downloaded = await PhotoTransferService.shared.downloadPhoto(item: item, serial: serial) {
                let thumb = await PhotoTransferService.shared.generateThumbnail(for: downloaded)
                await MainActor.run {
                    self.cachedURL = downloaded
                    if let thumb {
                        self.thumbnailImage = thumb
                    } else {
                        self.failedLoad = true
                    }
                }
            } else {
                await MainActor.run {
                    self.failedLoad = true
                }
            }
        }
    }

    private func openInPreview() {
        let existing = cachedURL
        Task {
            let url: URL?
            if let existing {
                url = existing
            } else {
                url = await PhotoTransferService.shared.downloadPhoto(item: item, serial: serial)
            }
            if let url {
                _ = await MainActor.run {
                    NSWorkspace.shared.open(url)
                }
            }
        }
    }

    private func saveToMac() {
        let existing = cachedURL
        Task {
            let url: URL?
            if let existing {
                url = existing
            } else {
                url = await PhotoTransferService.shared.downloadPhoto(item: item, serial: serial)
            }
            guard let sourceURL = url else { return }
            await MainActor.run {
                let panel = NSSavePanel()
                panel.nameFieldStringValue = item.name
                if panel.runModal() == .OK, let dest = panel.url {
                    try? FileManager.default.removeItem(at: dest)
                    try? FileManager.default.copyItem(at: sourceURL, to: dest)
                }
            }
        }
    }
}
