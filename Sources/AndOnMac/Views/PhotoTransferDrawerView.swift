import SwiftUI
import AppKit

public struct PhotoTransferDrawerView: View {
    @ObservedObject var appState: AppState
    @State private var photos: [PhotoItem] = []
    @State private var isLoading: Bool = false
    @State private var statusNote: String? = nil
    
    public init(appState: AppState) {
        self.appState = appState
    }
    
    public var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                HStack(spacing: 6) {
                    Image(systemName: "photo.stack")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(.blue)
                    Text("Медиатека телефона")
                        .font(.system(size: 13, weight: .bold))
                }
                Spacer()
                
                Button {
                    loadPhotos()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .help("Обновить")
                
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
                .help("Закрыть")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            
            Divider()
            
            if isLoading && photos.isEmpty {
                VStack(spacing: 12) {
                    Spacer()
                    ProgressView()
                    Text("Загрузка медиафайлов...")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                }
            } else if photos.isEmpty {
                VStack(spacing: 12) {
                    Spacer()
                    Image(systemName: "photo.on.rectangle.angled")
                        .font(.system(size: 36))
                        .foregroundColor(.secondary.opacity(0.6))
                    Text("Нет недавних фото")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    Text("Сделайте фото или скриншот на телефоне")
                        .font(.caption2)
                        .foregroundColor(.secondary.opacity(0.8))
                    Spacer()
                }
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 80), spacing: 8)], spacing: 8) {
                        ForEach(photos) { item in
                            PhotoThumbnailCell(item: item, serial: appState.selectedDevice?.id ?? "")
                        }
                    }
                    .padding(12)
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
                        Text("Перенести фото с Mac...")
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
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color.primary.opacity(0.03))
        }
        .frame(width: 290)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(.ultraThinMaterial)
                .shadow(color: Color.black.opacity(0.3), radius: 15, x: -5, y: 5)
        )
        .onAppear {
            loadPhotos()
        }
    }
    
    private func loadPhotos() {
        guard let device = appState.selectedDevice else { return }
        isLoading = true
        Task {
            let items = await PhotoTransferService.shared.fetchRecentPhotos(serial: device.id)
            await MainActor.run {
                self.photos = items
                self.isLoading = false
            }
        }
    }
    
    private func pickAndSendPhotos() {
        guard let device = appState.selectedDevice else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.image, .movie, .data]
        panel.prompt = "Отправить на телефон"
        
        if panel.runModal() == .OK {
            let urls = panel.urls
            Task {
                let res = await PhotoTransferService.shared.pushFiles(urls: urls, serial: device.id)
                await MainActor.run {
                    self.statusNote = res.message
                    if res.success {
                        loadPhotos()
                    }
                }
            }
        }
    }
}

// Single Photo Thumbnail with drag & drop support
private struct PhotoThumbnailCell: View {
    let item: PhotoItem
    let serial: String
    @State private var cachedURL: URL?
    @State private var thumbnailImage: NSImage?
    
    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            if let img = thumbnailImage {
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 80, height: 80)
                    .clipped()
                    .cornerRadius(8)
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
            
            if item.isScreenshot {
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
        .onAppear {
            ensureDownloaded()
        }
        .onDrag {
            if let local = cachedURL {
                let provider = NSItemProvider(object: local as NSURL)
                let ext = local.pathExtension.lowercased()
                let uti = (ext == "png") ? "public.png" : (ext == "mp4" ? "public.mpeg-4" : "public.jpeg")
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
        if let existing = item.localURL, let img = NSImage(contentsOf: existing) {
            self.cachedURL = existing
            self.thumbnailImage = img
            return
        }
        
        Task {
            if let downloaded = await PhotoTransferService.shared.downloadPhoto(item: item, serial: serial) {
                let img = NSImage(contentsOf: downloaded)
                await MainActor.run {
                    self.cachedURL = downloaded
                    self.thumbnailImage = img
                }
            }
        }
    }
}
