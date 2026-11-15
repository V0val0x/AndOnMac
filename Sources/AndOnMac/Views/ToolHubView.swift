import SwiftUI
import AppKit

/// "MCP Tool Hub" window for viewing, toggling, exporting, and importing Visual-to-MCP tools.
public struct ToolHubView: View {
    @ObservedObject var appState: AppState
    @ObservedObject private var registry = CustomMCPToolRegistry.shared

    @State private var showImportSheet: Bool = false
    @State private var importJSONText: String = ""
    @State private var editingTool: CustomMCPToolSchema? = nil
    @State private var statusBanner: String? = nil
    @State private var errorMessage: String? = nil

    public init(appState: AppState) {
        self.appState = appState
    }

    private var lang: AppLanguage { appState.lang }

    public var body: some View {
        VStack(spacing: 0) {
            // Header Toolbar
            HStack(spacing: 10) {
                Image(systemName: "wrench.and.screwdriver.fill")
                    .foregroundColor(.cyan)
                    .font(.title3)

                VStack(alignment: .leading, spacing: 2) {
                    Text("MCP Tool Hub")
                        .font(.headline)
                    Text("~/.andonmac/mcp_tools/ · \(registry.tools.filter(\.isEnabled).count)/\(registry.tools.count) " + L10n.tr("активно", "active", lang: lang))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                Button {
                    appState.triggerVisualMCPCapture()
                } label: {
                    Label(L10n.tr("Создать Tool", "Create Tool", lang: lang), systemImage: "plus.viewfinder")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)

                Button {
                    importJSONText = NSPasteboard.general.string(forType: .string) ?? ""
                    errorMessage = nil
                    showImportSheet = true
                } label: {
                    Label(L10n.tr("Импорт", "Import", lang: lang), systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button {
                    NSWorkspace.shared.open(registry.directoryURL)
                } label: {
                    Image(systemName: "folder")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help(L10n.tr("Открыть ~/.andonmac/mcp_tools/", "Open ~/.andonmac/mcp_tools/", lang: lang))
            }
            .padding(14)

            if let statusBanner {
                HStack {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                    Text(statusBanner)
                        .font(.caption.weight(.medium))
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(Color.green.opacity(0.12))
            }

            Divider()

            if registry.tools.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "square.dashed.inset.filled")
                        .font(.system(size: 38))
                        .foregroundColor(.secondary.opacity(0.6))
                    Text(L10n.tr("Нет пользовательских MCP-инструментов", "No Custom MCP Tools Yet", lang: lang))
                        .font(.headline)
                    Text(L10n.tr(
                        "Нажмите «Создать Tool» (или Cmd+Shift+M во время трансляции), чтобы выделить элемент на экране Android и превратить его в MCP-инструмент.",
                        "Click 'Create Tool' (or press Cmd+Shift+M while mirroring) to draw a box over any Android UI element and turn it into an MCP tool.",
                        lang: lang
                    ))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
            } else {
                List {
                    ForEach(registry.tools) { tool in
                        ToolHubRow(
                            tool: tool,
                            lang: lang,
                            onToggle: { enabled in
                                do {
                                    try registry.setEnabled(name: tool.name, enabled: enabled)
                                } catch {
                                    showBanner(error.localizedDescription)
                                }
                            },
                            onConfigure: {
                                editingTool = tool
                            },
                            onExport: {
                                do {
                                    _ = try registry.copyExportJSONToClipboard(name: tool.name)
                                    showBanner(L10n.tr("JSON скопирован в буфер обмена", "Copied JSON schema to clipboard", lang: lang))
                                } catch {
                                    showBanner(error.localizedDescription)
                                }
                            },
                            onDelete: {
                                do {
                                    try registry.deleteTool(name: tool.name)
                                    showBanner(L10n.tr("Инструмент удалён", "Deleted '\(tool.name)'", lang: lang))
                                } catch {
                                    showBanner(error.localizedDescription)
                                }
                            }
                        )
                    }
                }
                .listStyle(.inset)
            }
        }
        .frame(minWidth: 580, minHeight: 420)
        .onAppear {
            _ = registry.loadAllTools()
        }
        .sheet(isPresented: $showImportSheet) {
            importSheetView
        }
        .sheet(item: $editingTool) { tool in
            VisualMCPToolSheet(
                appState: appState,
                existingTool: tool,
                onSaved: { saved in
                    editingTool = nil
                    showBanner(L10n.tr("Настройки '\(saved.name)' сохранены", "Updated '\(saved.name)'", lang: lang))
                },
                onCancel: {
                    editingTool = nil
                }
            )
        }
    }

    private var importSheetView: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.tr("Импорт MCP Tool JSON", "Import MCP Tool JSON", lang: lang))
                .font(.headline)
            Text(L10n.tr(
                "Вставьте JSON-схему инструмента (например, из репозитория сообщества на GitHub):",
                "Paste a JSON tool schema (e.g. from a community GitHub repo):",
                lang: lang
            ))
            .font(.caption)
            .foregroundColor(.secondary)

            TextEditor(text: $importJSONText)
                .font(.system(size: 11, design: .monospaced))
                .frame(height: 220)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.25)))

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundColor(.red)
            }

            HStack {
                Button(L10n.tr("Отмена", "Cancel", lang: lang)) {
                    showImportSheet = false
                }
                .keyboardShortcut(.cancelAction)
                Spacer()
                Button(L10n.tr("Импортировать", "Import Tool", lang: lang)) {
                    do {
                        let imported = try registry.importFromJSON(importJSONText)
                        showImportSheet = false
                        showBanner(L10n.tr("Импортирован '\(imported.name)'", "Imported '\(imported.name)'", lang: lang))
                    } catch {
                        errorMessage = error.localizedDescription
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(importJSONText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(18)
        .frame(width: 480)
    }

    private func showBanner(_ text: String) {
        statusBanner = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.8) {
            if statusBanner == text {
                statusBanner = nil
            }
        }
    }
}

private struct ToolHubRow: View {
    let tool: CustomMCPToolSchema
    let lang: AppLanguage
    let onToggle: (Bool) -> Void
    let onConfigure: () -> Void
    let onExport: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Toggle("", isOn: Binding(
                get: { tool.isEnabled },
                set: { onToggle($0) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(tool.name)
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    Text(tool.action == .macro
                         ? "macro · \(tool.steps?.count ?? 0) steps"
                         : tool.action.rawValue)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background((tool.action == .macro ? Color.orange : Color.cyan).opacity(0.14))
                        .foregroundColor(tool.action == .macro ? .orange : .cyan)
                        .cornerRadius(4)
                }

                if !tool.description.isEmpty {
                    Text(tool.description)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }

                Text(targetSummary)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary.opacity(0.85))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            Button {
                onConfigure()
            } label: {
                Image(systemName: "slider.horizontal.3")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help(L10n.tr("Настроить параметры и лимиты", "Configure delays & limits", lang: lang))

            Button {
                onExport()
            } label: {
                Label(L10n.tr("Экспорт", "Export", lang: lang), systemImage: "doc.on.doc")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Button(role: .destructive) {
                onDelete()
            } label: {
                Image(systemName: "trash")
                    .foregroundColor(.red)
            }
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 4)
    }

    private var targetSummary: String {
        if tool.action == .macro {
            let params = tool.extractTemplateParameterNames()
            let paramDesc = params.isEmpty ? "" : " · params: \(params.map { "{{\($0)}}" }.joined(separator: ", "))"
            return "wait: \(tool.effectiveStepDelayMs())ms · cap: \(tool.effectiveMaxSteps()) steps/\(tool.effectiveMaxDurationSeconds())s\(paramDesc)"
        }
        if let rid = tool.target.resourceId, !rid.isEmpty {
            return "id: \(rid) · (\(tool.target.fallbackX), \(tool.target.fallbackY))"
        }
        if let text = tool.target.text, !text.isEmpty {
            return "text: \"\(text)\" · (\(tool.target.fallbackX), \(tool.target.fallbackY))"
        }
        return "coords: (\(tool.target.fallbackX), \(tool.target.fallbackY))"
    }
}
