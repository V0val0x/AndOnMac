import SwiftUI
import AppKit
import UniformTypeIdentifiers

public struct FileBrowserView: View {
    @ObservedObject var appState: AppState
    @State private var storageRoots: [String] = ["/sdcard"]
    @State private var currentPath: String = "/sdcard"
    @State private var items: [AndroidFileItem] = []
    @State private var searchText: String = ""
    @State private var sortOrder: FileSortOrder = .name
    @State private var showHidden: Bool = false
    @State private var isLoading: Bool = false
    @State private var isTransferring: Bool = false
    @State private var statusMessage: String? = nil
    @State private var errorMessage: String? = nil
    @State private var isDropTargeted: Bool = false

    // Modals
    @State private var showNewFolderAlert: Bool = false
    @State private var newFolderName: String = ""
    @State private var renamingItem: AndroidFileItem? = nil
    @State private var renameText: String = ""
    @State private var deletingItem: AndroidFileItem? = nil

    public init(appState: AppState) {
        self.appState = appState
    }

    private var filteredItems: [AndroidFileItem] {
        let base = FileBrowserService.sortItems(items, by: sortOrder)
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return base }
        return base.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    private var canGoUp: Bool {
        !storageRoots.contains(currentPath) && currentPath != "/"
    }

    public var body: some View {
        let lang = appState.lang
        VStack(spacing: 0) {
            // Path & Toolbar
            HStack(spacing: 6) {
                Button {
                    navigateUp()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 11, weight: .bold))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!canGoUp)
                .help(L10n.tr("Наверх", "Up", lang: lang))

                Menu {
                    ForEach(storageRoots, id: \.self) { root in
                        Button(root == "/sdcard" ? L10n.tr("Внутренняя память (/sdcard)", "Internal Storage (/sdcard)", lang: lang) : root) {
                            navigate(to: root)
                        }
                    }
                    Divider()
                    ForEach(["DCIM", "Download", "Documents", "Pictures", "Music", "Movies"], id: \.self) { sub in
                        Button(sub) {
                            navigate(to: "/sdcard/\(sub)")
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "internaldrive")
                            .font(.system(size: 10))
                        Text(currentPath)
                            .font(.system(size: 11, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .menuStyle(.borderlessButton)

                Button {
                    newFolderName = ""
                    showNewFolderAlert = true
                } label: {
                    Image(systemName: "folder.badge.plus")
                        .font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .help(L10n.tr("Новая папка", "New Folder", lang: lang))

                Menu {
                    ForEach(FileSortOrder.allCases) { order in
                        Button {
                            sortOrder = order
                        } label: {
                            if sortOrder == order {
                                Label(order.title(lang: lang), systemImage: "checkmark")
                            } else {
                                Text(order.title(lang: lang))
                            }
                        }
                    }
                    Divider()
                    Toggle(L10n.tr("Скрытые файлы", "Show Hidden Files", lang: lang), isOn: $showHidden)
                } label: {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                        .font(.system(size: 12))
                }
                .menuStyle(.borderlessButton)
                .help(L10n.tr("Сортировка и вид", "Sort & View", lang: lang))

                Button {
                    loadDirectory()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .help(L10n.tr("Обновить", "Refresh", lang: lang))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)

            // Search bar
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                TextField(L10n.tr("Поиск в папке...", "Search in folder...", lang: lang), text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11))
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Color.primary.opacity(0.06))
            .cornerRadius(8)
            .padding(.horizontal, 12)
            .padding(.bottom, 8)

            Divider()

            // Directory Listing (Drop Target from Mac Finder)
            ZStack {
                if isLoading && items.isEmpty {
                    VStack(spacing: 10) {
                        Spacer()
                        ProgressView()
                        Text(L10n.tr("Чтение файлов...", "Loading files...", lang: lang))
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Spacer()
                    }
                    .frame(maxWidth: .infinity)
                } else if let error = errorMessage {
                    VStack(spacing: 8) {
                        Spacer()
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 28))
                            .foregroundColor(.orange)
                        Text(error)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 16)
                        Spacer()
                    }
                    .frame(maxWidth: .infinity)
                } else if filteredItems.isEmpty {
                    VStack(spacing: 8) {
                        Spacer()
                        Image(systemName: "folder")
                            .font(.system(size: 30))
                            .foregroundColor(.secondary.opacity(0.6))
                        Text(L10n.tr("Папка пуста", "Folder is empty", lang: lang))
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text(L10n.tr("Перетащите файлы с Mac сюда для загрузки", "Drag files from Mac here to upload", lang: lang))
                            .font(.caption2)
                            .foregroundColor(.secondary.opacity(0.75))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 16)
                        Spacer()
                    }
                    .frame(maxWidth: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(filteredItems) { item in
                                FileRowView(
                                    item: item,
                                    lang: lang,
                                    onOpen: { openItem(item) },
                                    onSaveToMac: { saveItemToMac(item) },
                                    onRename: {
                                        renamingItem = item
                                        renameText = item.name
                                    },
                                    onDelete: {
                                        deletingItem = item
                                    },
                                    onProvideDragURL: {
                                        await provideDragFile(item)
                                    }
                                )
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                    }
                }

                if isDropTargeted {
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(Color.blue, style: StrokeStyle(lineWidth: 2, dash: [6]))
                        .background(Color.blue.opacity(0.1))
                        .padding(6)
                        .overlay(
                            Text(L10n.tr("Отпустите для загрузки в \(currentPath)", "Drop to upload to \(currentPath)", lang: lang))
                                .font(.caption.bold())
                                .foregroundColor(.blue)
                                .padding(8)
                                .background(.ultraThinMaterial)
                                .cornerRadius(8)
                        )
                }
            }
            .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
                handleDrop(providers: providers)
            }

            Divider()

            // Bottom Action Bar
            HStack(spacing: 8) {
                Button {
                    uploadFromMac()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.up.doc.fill")
                        Text(L10n.tr("Загрузить...", "Upload...", lang: lang))
                    }
                    .font(.caption.bold())
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isTransferring)

                Button {
                    backupCurrentFolderToMac()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.down.doc.fill")
                        Text(L10n.tr("Скачать папку", "Pull Folder", lang: lang))
                    }
                    .font(.caption.bold())
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isTransferring)

                Spacer()

                if isTransferring {
                    ProgressView()
                        .scaleEffect(0.6)
                } else if let status = statusMessage {
                    Text(status)
                        .font(.caption2)
                        .foregroundColor(.green)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(Color.primary.opacity(0.03))
        }
        .onAppear {
            loadRootsAndDirectory()
        }
        .onChange(of: showHidden) { _, _ in
            loadDirectory()
        }
        .alert(L10n.tr("Новая папка", "New Folder", lang: lang), isPresented: $showNewFolderAlert) {
            TextField(L10n.tr("Имя папки", "Folder name", lang: lang), text: $newFolderName)
            Button(L10n.tr("Создать", "Create", lang: lang)) {
                createFolder()
            }
            Button(L10n.tr("Отмена", "Cancel", lang: lang), role: .cancel) {}
        }
        .alert(
            L10n.tr("Переименовать", "Rename", lang: lang),
            isPresented: Binding(
                get: { renamingItem != nil },
                set: { if !$0 { renamingItem = nil } }
            )
        ) {
            TextField(L10n.tr("Новое имя", "New name", lang: lang), text: $renameText)
            Button(L10n.tr("Сохранить", "Save", lang: lang)) {
                confirmRename()
            }
            Button(L10n.tr("Отмена", "Cancel", lang: lang), role: .cancel) {
                renamingItem = nil
            }
        }
        .alert(
            L10n.tr("Удалить объект?", "Delete item?", lang: lang),
            isPresented: Binding(
                get: { deletingItem != nil },
                set: { if !$0 { deletingItem = nil } }
            )
        ) {
            Button(L10n.tr("Удалить", "Delete", lang: lang), role: .destructive) {
                confirmDelete()
            }
            Button(L10n.tr("Отмена", "Cancel", lang: lang), role: .cancel) {
                deletingItem = nil
            }
        } message: {
            Text(deletingItem?.name ?? "")
        }
    }

    private func loadRootsAndDirectory() {
        guard let serial = appState.selectedDevice?.id else { return }
        Task {
            let roots = await FileBrowserService.shared.listStorageRoots(serial: serial)
            await MainActor.run {
                self.storageRoots = roots
            }
            loadDirectory()
        }
    }

    private func navigate(to path: String) {
        currentPath = path
        searchText = ""
        loadDirectory()
    }

    private func navigateUp() {
        guard canGoUp else { return }
        let parent = (currentPath as NSString).deletingLastPathComponent
        navigate(to: parent.isEmpty ? "/sdcard" : parent)
    }

    private func loadDirectory() {
        guard let serial = appState.selectedDevice?.id else { return }
        let pathToLoad = currentPath
        let hidden = showHidden
        let order = sortOrder
        isLoading = true
        errorMessage = nil
        Task {
            do {
                let loaded = try await FileBrowserService.shared.listDirectory(
                    serial: serial,
                    path: pathToLoad,
                    includeHidden: hidden,
                    sortOrder: order
                )
                await MainActor.run {
                    self.items = loaded
                    self.isLoading = false
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.isLoading = false
                }
            }
        }
    }

    private func openItem(_ item: AndroidFileItem) {
        if item.isDirectory {
            navigate(to: item.path)
            return
        }
        guard let serial = appState.selectedDevice?.id else { return }
        isTransferring = true
        Task {
            do {
                let localURL = try await FileBrowserService.shared.pullToCache(serial: serial, item: item)
                await MainActor.run {
                    self.isTransferring = false
                    NSWorkspace.shared.open(localURL)
                }
            } catch {
                await MainActor.run {
                    self.isTransferring = false
                    self.statusMessage = L10n.tr("Ошибка открытия", "Failed to open", lang: appState.lang)
                }
            }
        }
    }

    private func saveItemToMac(_ item: AndroidFileItem) {
        guard let serial = appState.selectedDevice?.id else { return }
        let lang = appState.lang
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = L10n.tr("Сохранить сюда", "Save Here", lang: lang)
        guard panel.runModal() == .OK, let destDir = panel.url else { return }

        let destURL = destDir.appendingPathComponent(item.name)
        isTransferring = true
        Task {
            do {
                try await FileBrowserService.shared.pullItem(serial: serial, remotePath: item.path, to: destURL)
                await MainActor.run {
                    self.isTransferring = false
                    self.statusMessage = L10n.tr("Сохранено: \(item.name)", "Saved: \(item.name)", lang: lang)
                }
            } catch {
                await MainActor.run {
                    self.isTransferring = false
                    self.statusMessage = L10n.tr("Ошибка сохранения", "Save failed", lang: lang)
                }
            }
        }
    }

    private func backupCurrentFolderToMac() {
        guard let serial = appState.selectedDevice?.id else { return }
        let lang = appState.lang
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = L10n.tr("Выгрузить папку сюда", "Pull Folder Here", lang: lang)
        guard panel.runModal() == .OK, let destDir = panel.url else { return }

        let folderName = (currentPath as NSString).lastPathComponent
        let destURL = destDir.appendingPathComponent(folderName.isEmpty ? "sdcard" : folderName)
        let sourcePath = currentPath
        isTransferring = true
        Task {
            do {
                try await FileBrowserService.shared.pullItem(serial: serial, remotePath: sourcePath, to: destURL)
                await MainActor.run {
                    self.isTransferring = false
                    self.statusMessage = L10n.tr("Папка сохранена", "Folder pulled", lang: lang)
                }
            } catch {
                await MainActor.run {
                    self.isTransferring = false
                    self.statusMessage = L10n.tr("Ошибка выгрузки", "Pull failed", lang: lang)
                }
            }
        }
    }

    private func uploadFromMac() {
        guard let serial = appState.selectedDevice?.id else { return }
        let lang = appState.lang
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = L10n.tr("Загрузить на телефон", "Upload to Phone", lang: lang)
        guard panel.runModal() == .OK else { return }
        uploadURLs(panel.urls, serial: serial)
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard let serial = appState.selectedDevice?.id else { return false }
        for provider in providers {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                guard let data = item as? Data,
                      let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                Task { @MainActor in
                    self.uploadURLs([url], serial: serial)
                }
            }
        }
        return true
    }

    private func uploadURLs(_ urls: [URL], serial: String) {
        let lang = appState.lang
        let targetDir = currentPath
        isTransferring = true
        Task {
            let res = await FileBrowserService.shared.pushItems(serial: serial, localURLs: urls, to: targetDir)
            await MainActor.run {
                self.isTransferring = false
                if res.succeeded > 0 {
                    self.statusMessage = L10n.tr("Загружено: \(res.succeeded)", "Uploaded: \(res.succeeded)", lang: lang)
                    self.loadDirectory()
                } else {
                    self.statusMessage = L10n.tr("Ошибка загрузки", "Upload failed", lang: lang)
                }
            }
        }
    }

    private func createFolder() {
        guard let serial = appState.selectedDevice?.id else { return }
        let trimmed = newFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let newPath = (currentPath as NSString).appendingPathComponent(trimmed)
        Task {
            try? await FileBrowserService.shared.createDirectory(serial: serial, path: newPath)
            await MainActor.run {
                self.loadDirectory()
            }
        }
    }

    private func confirmRename() {
        guard let serial = appState.selectedDevice?.id, let item = renamingItem else { return }
        let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != item.name else {
            renamingItem = nil
            return
        }
        let parent = (item.path as NSString).deletingLastPathComponent
        let newPath = (parent as NSString).appendingPathComponent(trimmed)
        renamingItem = nil
        Task {
            try? await FileBrowserService.shared.renameItem(serial: serial, from: item.path, to: newPath)
            await MainActor.run {
                self.loadDirectory()
            }
        }
    }

    private func confirmDelete() {
        guard let serial = appState.selectedDevice?.id, let item = deletingItem else { return }
        deletingItem = nil
        Task {
            try? await FileBrowserService.shared.deleteItem(serial: serial, path: item.path)
            await MainActor.run {
                self.loadDirectory()
            }
        }
    }

    private func provideDragFile(_ item: AndroidFileItem) async -> URL? {
        guard let serial = appState.selectedDevice?.id else { return nil }
        return try? await FileBrowserService.shared.pullToCache(serial: serial, item: item)
    }
}

private struct FileRowView: View {
    let item: AndroidFileItem
    let lang: AppLanguage
    let onOpen: () -> Void
    let onSaveToMac: () -> Void
    let onRename: () -> Void
    let onDelete: () -> Void
    let onProvideDragURL: () async -> URL?

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: item.sfSymbolName)
                .font(.system(size: 14))
                .foregroundColor(item.isDirectory ? .blue : .secondary)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 1) {
                Text(item.name)
                    .font(.system(size: 11.5, weight: item.isDirectory ? .semibold : .regular))
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(item.formattedSize)
                    if !item.formattedDate.isEmpty {
                        Text("• \(item.formattedDate)")
                    }
                }
                .font(.system(size: 9.5))
                .foregroundColor(.secondary)
            }

            Spacer()

            if item.isDirectory {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9))
                    .foregroundColor(.secondary.opacity(0.6))
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Color.primary.opacity(0.03))
        .cornerRadius(7)
        .contentShape(Rectangle())
        .onTapGesture(count: item.isDirectory ? 1 : 2) {
            onOpen()
        }
        .contextMenu {
            Button(item.isDirectory
                   ? L10n.tr("Открыть папку", "Open Folder", lang: lang)
                   : L10n.tr("Открыть на Mac", "Open on Mac", lang: lang)) {
                onOpen()
            }
            Button(L10n.tr("Сохранить на Mac...", "Save to Mac...", lang: lang)) {
                onSaveToMac()
            }
            Divider()
            Button(L10n.tr("Переименовать...", "Rename...", lang: lang)) {
                onRename()
            }
            Button(L10n.tr("Удалить", "Delete", lang: lang), role: .destructive) {
                onDelete()
            }
        }
        .onDrag {
            let provider = NSItemProvider()
            if !item.isDirectory {
                provider.registerFileRepresentation(forTypeIdentifier: UTType.data.identifier, fileOptions: [], visibility: .all) { completion in
                    Task {
                        let url = await onProvideDragURL()
                        completion(url, false, nil)
                    }
                    return nil
                }
            }
            return provider
        }
    }
}
