import SwiftUI

/// Native macOS sheet for naming, parameterizing, and saving a visually captured MCP tool.
public struct VisualMCPToolSheet: View {
    @ObservedObject var appState: AppState
    public let matchedNode: MatchedVisualNode
    public let onSaved: (CustomMCPToolSchema) -> Void
    public let onCancel: () -> Void

    @State private var toolName: String = ""
    @State private var toolDescription: String = ""
    @State private var actionType: VisualMCPActionType = .readTextUIAutomator
    @State private var parameters: [CustomMCPParameter] = []
    @State private var errorMessage: String? = nil

    public init(
        appState: AppState,
        matchedNode: MatchedVisualNode,
        onSaved: @escaping (CustomMCPToolSchema) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.appState = appState
        self.matchedNode = matchedNode
        self.onSaved = onSaved
        self.onCancel = onCancel
    }

    private var lang: AppLanguage { appState.lang }

    private var isNameValid: Bool {
        CustomMCPToolSchema.isValidToolName(toolName.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: "wand.and.stars")
                    .foregroundColor(.cyan)
                Text(L10n.tr("Создать MCP-инструмент", "Create MCP Tool", lang: lang))
                    .font(.headline)
                Spacer()
                Button(L10n.tr("Отмена", "Cancel", lang: lang)) {
                    onCancel()
                }
                .keyboardShortcut(.cancelAction)
            }

            // Matched Android Node Summary
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.tr("Распознанный элемент Android UI", "Matched Android UI Node", lang: lang))
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.secondary)

                if let node = matchedNode.node {
                    HStack(spacing: 8) {
                        if !node.class.isEmpty {
                            Text(node.class)
                                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.cyan.opacity(0.15))
                                .cornerRadius(4)
                        }
                        if !node.resource_id.isEmpty {
                            Text(node.resource_id)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(.primary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    if !node.text.isEmpty || !node.content_desc.isEmpty {
                        Text(node.text.isEmpty ? node.content_desc : node.text)
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                            .lineLimit(2)
                    }
                } else {
                    Text(L10n.tr(
                        "UI-узел не найден — будут использованы координаты (\(matchedNode.fallbackCenterX), \(matchedNode.fallbackCenterY)) / OCR.",
                        "No semantic UI node matched — falling back to (\(matchedNode.fallbackCenterX), \(matchedNode.fallbackCenterY)) / Vision OCR.",
                        lang: lang
                    ))
                    .font(.system(size: 11))
                    .foregroundColor(.orange)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.05))
            .cornerRadius(8)

            // Tool Metadata
            VStack(alignment: .leading, spacing: 8) {
                Text(L10n.tr("Имя инструмента (snake_case)", "Tool Name (snake_case)", lang: lang))
                    .font(.caption.weight(.semibold))
                TextField("get_bank_balance", text: $toolName)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))

                if !toolName.isEmpty && !isNameValid {
                    Text(L10n.tr(
                        "Допустимы только строчные латинские буквы, цифры и '_' (от 2 символов, не совпадает со встроенными).",
                        "Use 2-64 lowercase letters, digits, or '_', without colliding with built-in tools.",
                        lang: lang
                    ))
                    .font(.caption2)
                    .foregroundColor(.red)
                }

                Text(L10n.tr("Описание для ИИ-агента", "Description for AI Agent", lang: lang))
                    .font(.caption.weight(.semibold))
                TextField(
                    L10n.tr("Например: Получить текущий баланс с экрана банка", "e.g. Read the current account balance from screen", lang: lang),
                    text: $toolDescription
                )
                .textFieldStyle(.roundedBorder)

                Text(L10n.tr("Действие", "Action", lang: lang))
                    .font(.caption.weight(.semibold))
                Picker("", selection: $actionType) {
                    ForEach(VisualMCPActionType.allCases) { action in
                        Text(action.localizedTitle(lang: lang)).tag(action)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
            }

            // Dynamic Parameters
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(L10n.tr("Параметры (опционально)", "Parameters (Optional)", lang: lang))
                        .font(.caption.weight(.semibold))
                    Spacer()
                    Button {
                        parameters.append(CustomMCPParameter(name: "param_\(parameters.count + 1)", type: "string", description: "", required: true))
                    } label: {
                        Label(L10n.tr("Добавить", "Add", lang: lang), systemImage: "plus.circle")
                            .font(.caption)
                    }
                    .buttonStyle(.link)
                }

                if !parameters.isEmpty {
                    ScrollView {
                        VStack(spacing: 6) {
                            ForEach(parameters.indices, id: \.self) { idx in
                                HStack(spacing: 6) {
                                    TextField("name", text: $parameters[idx].name)
                                        .textFieldStyle(.roundedBorder)
                                        .font(.system(size: 11, design: .monospaced))
                                        .frame(width: 100)

                                    Picker("", selection: $parameters[idx].type) {
                                        ForEach(CustomMCPParameter.allowedTypes, id: \.self) { t in
                                            Text(t).tag(t)
                                        }
                                    }
                                    .labelsHidden()
                                    .frame(width: 82)

                                    TextField("description", text: $parameters[idx].description)
                                        .textFieldStyle(.roundedBorder)
                                        .font(.system(size: 11))

                                    Toggle("Req", isOn: $parameters[idx].required)
                                        .toggleStyle(.checkbox)
                                        .controlSize(.small)

                                    Button {
                                        parameters.remove(at: idx)
                                    } label: {
                                        Image(systemName: "trash")
                                            .foregroundColor(.red)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                    .frame(maxHeight: 110)
                }
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundColor(.red)
            }

            HStack {
                Spacer()
                Button(L10n.tr("Сохранить в Tool Hub", "Save to Tool Hub", lang: lang)) {
                    save()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!isNameValid)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 440)
        .onAppear {
            if let node = matchedNode.node {
                if node.clickable && node.text.isEmpty {
                    actionType = .tapElement
                } else if !node.text.isEmpty {
                    actionType = .readTextUIAutomator
                } else {
                    actionType = .readTextOCR
                }
            } else {
                actionType = .readTextOCR
            }
        }
    }

    private func save() {
        let trimmedName = toolName.trimmingCharacters(in: .whitespacesAndNewlines)
        let schema = CustomMCPToolSchema(
            name: trimmedName,
            description: toolDescription.trimmingCharacters(in: .whitespacesAndNewlines),
            appPackageHint: nil,
            isEnabled: true,
            action: actionType,
            target: matchedNode.toVisualNodeTarget(),
            parameters: parameters.map {
                CustomMCPParameter(
                    name: $0.name.trimmingCharacters(in: .whitespacesAndNewlines),
                    type: $0.type,
                    description: $0.description.trimmingCharacters(in: .whitespacesAndNewlines),
                    required: $0.required
                )
            }
        )
        do {
            try CustomMCPToolRegistry.shared.saveTool(schema)
            onSaved(schema)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
