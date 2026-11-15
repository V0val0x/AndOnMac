import SwiftUI

/// Native macOS sheet for naming, parameterizing, configuring per-tool limits, and saving a Visual MCP tool or Macro.
public struct VisualMCPToolSheet: View {
    @ObservedObject var appState: AppState
    public let matchedNode: MatchedVisualNode?
    public let existingTool: CustomMCPToolSchema?
    public let onSaved: (CustomMCPToolSchema) -> Void
    public let onCancel: () -> Void

    @State private var toolName: String = ""
    @State private var toolDescription: String = ""
    @State private var actionType: VisualMCPActionType = .readTextUIAutomator
    @State private var target: VisualNodeTarget
    @State private var macroSteps: [VisualMacroStep]
    @State private var parameters: [CustomMCPParameter] = []

    // Per-tool execution overrides (nil = inherit General Settings)
    @State private var useCustomStepDelay: Bool = false
    @State private var customStepDelayMs: Int
    @State private var useCustomMaxSteps: Bool = false
    @State private var customMaxSteps: Int
    @State private var useCustomMaxDuration: Bool = false
    @State private var customMaxDurationSeconds: Int
    @State private var useCustomSelfHealing: Bool = false
    @State private var customSelfHealingEnabled: Bool

    @State private var errorMessage: String? = nil

    /// Single-element capture initializer.
    public init(
        appState: AppState,
        matchedNode: MatchedVisualNode,
        onSaved: @escaping (CustomMCPToolSchema) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.appState = appState
        self.matchedNode = matchedNode
        self.existingTool = nil
        self.onSaved = onSaved
        self.onCancel = onCancel
        _target = State(initialValue: matchedNode.toVisualNodeTarget())
        _macroSteps = State(initialValue: [])
        _customStepDelayMs = State(initialValue: appState.macroDefaultStepDelayMs)
        _customMaxSteps = State(initialValue: appState.macroMaxSteps)
        _customMaxDurationSeconds = State(initialValue: appState.macroMaxTotalWaitSeconds)
        _customSelfHealingEnabled = State(initialValue: appState.mcpSelfHealingEnabled)
    }

    /// Multi-step macro capture initializer.
    public init(
        appState: AppState,
        macroSteps: [VisualMacroStep],
        onSaved: @escaping (CustomMCPToolSchema) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.appState = appState
        self.matchedNode = nil
        self.existingTool = nil
        self.onSaved = onSaved
        self.onCancel = onCancel
        let firstTarget = macroSteps.first?.target ?? VisualNodeTarget(
            resourceId: nil, className: nil, text: nil, contentDesc: nil,
            fallbackX: 540, fallbackY: 1200, normalizedRect: [0.4, 0.4, 0.2, 0.1]
        )
        _actionType = State(initialValue: .macro)
        _target = State(initialValue: firstTarget)
        _macroSteps = State(initialValue: macroSteps)

        let autoParams = CustomMCPToolSheetHelpers.extractAutoParameters(from: macroSteps)
        _parameters = State(initialValue: autoParams)
        _customStepDelayMs = State(initialValue: appState.macroDefaultStepDelayMs)
        _customMaxSteps = State(initialValue: appState.macroMaxSteps)
        _customMaxDurationSeconds = State(initialValue: appState.macroMaxTotalWaitSeconds)
        _customSelfHealingEnabled = State(initialValue: appState.mcpSelfHealingEnabled)
    }

    /// Existing tool configuration / edit initializer (used from Tool Hub).
    public init(
        appState: AppState,
        existingTool: CustomMCPToolSchema,
        onSaved: @escaping (CustomMCPToolSchema) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.appState = appState
        self.matchedNode = nil
        self.existingTool = existingTool
        self.onSaved = onSaved
        self.onCancel = onCancel
        _toolName = State(initialValue: existingTool.name)
        _toolDescription = State(initialValue: existingTool.description)
        _actionType = State(initialValue: existingTool.action)
        _target = State(initialValue: existingTool.target)
        _macroSteps = State(initialValue: existingTool.steps ?? [])
        _parameters = State(initialValue: existingTool.parameters)
        _useCustomStepDelay = State(initialValue: existingTool.defaultStepDelayMs != nil)
        _customStepDelayMs = State(initialValue: existingTool.defaultStepDelayMs ?? appState.macroDefaultStepDelayMs)
        _useCustomMaxSteps = State(initialValue: existingTool.maxSteps != nil)
        _customMaxSteps = State(initialValue: existingTool.maxSteps ?? appState.macroMaxSteps)
        _useCustomMaxDuration = State(initialValue: existingTool.maxDurationSeconds != nil)
        _customMaxDurationSeconds = State(initialValue: existingTool.maxDurationSeconds ?? appState.macroMaxTotalWaitSeconds)
        _useCustomSelfHealing = State(initialValue: existingTool.selfHealingEnabled != nil)
        _customSelfHealingEnabled = State(initialValue: existingTool.selfHealingEnabled ?? appState.mcpSelfHealingEnabled)
    }

    private var lang: AppLanguage { appState.lang }

    private var isNameValid: Bool {
        CustomMCPToolSchema.isValidToolName(toolName.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private var canSave: Bool {
        isNameValid && (actionType != .macro || !macroSteps.isEmpty)
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Image(systemName: actionType == .macro ? "record.circle.fill" : "wand.and.stars")
                        .foregroundColor(actionType == .macro ? .red : .cyan)
                    Text(existingTool != nil
                         ? L10n.tr("Настройки MCP Tool", "Configure MCP Tool", lang: lang)
                         : (actionType == .macro
                            ? L10n.tr("Создать MCP-макрос", "Create MCP Macro Tool", lang: lang)
                            : L10n.tr("Создать MCP-инструмент", "Create MCP Tool", lang: lang)))
                        .font(.headline)
                    Spacer()
                    Button(L10n.tr("Отмена", "Cancel", lang: lang)) {
                        onCancel()
                    }
                    .keyboardShortcut(.cancelAction)
                }

                if actionType == .macro {
                    macroStepsSummarySection
                } else {
                    nodeSummarySection
                }

                // Tool Metadata
                VStack(alignment: .leading, spacing: 8) {
                    Text(L10n.tr("Имя инструмента (snake_case)", "Tool Name (snake_case)", lang: lang))
                        .font(.caption.weight(.semibold))
                    TextField(actionType == .macro ? "send_whatsapp_message" : "get_bank_balance", text: $toolName)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                        .disabled(existingTool != nil)

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
                        actionType == .macro
                        ? L10n.tr("Например: Открыть поиск, ввести контакт и отправить сообщение", "e.g. Search contact, type {{message_body}}, and tap Send", lang: lang)
                        : L10n.tr("Например: Получить текущий баланс с экрана банка", "e.g. Read the current account balance from screen", lang: lang),
                        text: $toolDescription
                    )
                    .textFieldStyle(.roundedBorder)

                    if actionType != .macro {
                        Text(L10n.tr("Действие", "Action", lang: lang))
                            .font(.caption.weight(.semibold))
                        Picker("", selection: $actionType) {
                            ForEach(VisualMCPActionType.singleStepCases) { action in
                                Text(action.localizedTitle(lang: lang)).tag(action)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                    }
                }

                // Dynamic Parameters
                parametersSection

                // Per-Tool Execution & Self-Healing Overrides
                perToolSettingsSection

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
                    .disabled(!canSave)
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(18)
        }
        .frame(width: 490, height: actionType == .macro ? 590 : 510)
        .onAppear {
            if existingTool == nil, actionType != .macro, let node = matchedNode?.node {
                if node.clickable && node.text.isEmpty {
                    actionType = .tapElement
                } else if !node.text.isEmpty {
                    actionType = .readTextUIAutomator
                } else {
                    actionType = .readTextOCR
                }
            } else if existingTool == nil, actionType != .macro {
                actionType = .readTextOCR
            }
        }
    }

    @ViewBuilder
    private var nodeSummarySection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L10n.tr("Целевой элемент Android UI", "Target Android UI Node", lang: lang))
                .font(.caption.weight(.semibold))
                .foregroundColor(.secondary)

            if let rid = target.resourceId, !rid.isEmpty {
                Text("id: \(rid)")
                    .font(.system(size: 11, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if let text = target.text ?? target.contentDesc, !text.isEmpty {
                Text(text)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .lineLimit(2)
            }
            Text("fallback coords: (\(target.fallbackX), \(target.fallbackY))")
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.secondary)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.05))
        .cornerRadius(8)
    }

    @ViewBuilder
    private var macroStepsSummarySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L10n.tr("Записанные шаги (\(macroSteps.count))", "Recorded Macro Steps (\(macroSteps.count))", lang: lang))
                .font(.caption.weight(.semibold))
                .foregroundColor(.secondary)

            ForEach(macroSteps.indices, id: \.self) { idx in
                HStack(spacing: 8) {
                    Text("\(idx + 1).")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundColor(.secondary)

                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(macroSteps[idx].action.rawValue)
                                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(Color.cyan.opacity(0.15))
                                .cornerRadius(4)
                            if let tpl = macroSteps[idx].textTemplate, !tpl.isEmpty {
                                Text(tpl)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundColor(.primary)
                                    .lineLimit(1)
                            }
                        }
                        let stepTarget = macroSteps[idx].target
                        Text(stepTarget.resourceId ?? stepTarget.text ?? stepTarget.contentDesc ?? "(\(stepTarget.fallbackX), \(stepTarget.fallbackY))")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }

                    Spacer()

                    Stepper(
                        value: Binding(
                            get: { macroSteps[idx].delayAfterMs ?? (useCustomStepDelay ? customStepDelayMs : appState.macroDefaultStepDelayMs) },
                            set: { macroSteps[idx].delayAfterMs = $0 }
                        ),
                        in: 0...MCPExecutionDefaults.maxStepDelayMs,
                        step: 50
                    ) {
                        Text("\(macroSteps[idx].delayAfterMs ?? (useCustomStepDelay ? customStepDelayMs : appState.macroDefaultStepDelayMs))ms")
                            .font(.system(size: 10, design: .monospaced))
                            .frame(width: 48, alignment: .trailing)
                    }
                    .controlSize(.small)

                    Button {
                        macroSteps.remove(at: idx)
                    } label: {
                        Image(systemName: "trash")
                            .foregroundColor(.red)
                    }
                    .buttonStyle(.plain)
                    .disabled(macroSteps.count <= 1)
                }
                .padding(8)
                .background(Color.primary.opacity(0.05))
                .cornerRadius(7)
            }
        }
    }

    @ViewBuilder
    private var parametersSection: some View {
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
                VStack(spacing: 6) {
                    ForEach(parameters.indices, id: \.self) { idx in
                        HStack(spacing: 6) {
                            TextField("name", text: $parameters[idx].name)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 11, design: .monospaced))
                                .frame(width: 115)

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
        }
    }

    @ViewBuilder
    private var perToolSettingsSection: some View {
        DisclosureGroup(
            L10n.tr("Настройки выполнения и Self-Healing для этого инструмента", "Per-Tool Limits & Self-Healing Overrides", lang: lang)
        ) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Toggle(
                        L10n.tr("Свой Self-Healing Vision OCR", "Override Self-Healing Vision OCR", lang: lang),
                        isOn: $useCustomSelfHealing
                    )
                    .toggleStyle(.checkbox)
                    Spacer()
                    if useCustomSelfHealing {
                        Toggle("", isOn: $customSelfHealingEnabled)
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.small)
                    } else {
                        Text(appState.mcpSelfHealingEnabled ? L10n.tr("Общее: Вкл", "Default: On", lang: lang) : L10n.tr("Общее: Выкл", "Default: Off", lang: lang))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                if actionType == .macro {
                    HStack {
                        Toggle(
                            L10n.tr("Своя пауза по умолчанию", "Override Default Step Wait", lang: lang),
                            isOn: $useCustomStepDelay
                        )
                        .toggleStyle(.checkbox)
                        Spacer()
                        if useCustomStepDelay {
                            Stepper(
                                value: $customStepDelayMs,
                                in: MCPExecutionDefaults.minStepDelayMs...MCPExecutionDefaults.maxStepDelayMs,
                                step: 50
                            ) {
                                Text("\(customStepDelayMs) ms")
                                    .font(.system(size: 11, design: .monospaced))
                            }
                            .controlSize(.small)
                        } else {
                            Text("\(appState.macroDefaultStepDelayMs) ms")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(.secondary)
                        }
                    }

                    HStack {
                        Toggle(
                            L10n.tr("Свой лимит шагов", "Override Max Steps", lang: lang),
                            isOn: $useCustomMaxSteps
                        )
                        .toggleStyle(.checkbox)
                        Spacer()
                        if useCustomMaxSteps {
                            Stepper(
                                value: $customMaxSteps,
                                in: MCPExecutionDefaults.minMaxSteps...MCPExecutionDefaults.maxMaxSteps,
                                step: 1
                            ) {
                                Text("\(customMaxSteps)")
                                    .font(.system(size: 11, design: .monospaced))
                            }
                            .controlSize(.small)
                        } else {
                            Text("\(appState.macroMaxSteps)")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(.secondary)
                        }
                    }

                    HStack {
                        Toggle(
                            L10n.tr("Свой лимит времени", "Override Duration Cap", lang: lang),
                            isOn: $useCustomMaxDuration
                        )
                        .toggleStyle(.checkbox)
                        Spacer()
                        if useCustomMaxDuration {
                            Stepper(
                                value: $customMaxDurationSeconds,
                                in: MCPExecutionDefaults.minMaxDurationSeconds...MCPExecutionDefaults.maxMaxDurationSeconds,
                                step: 1
                            ) {
                                Text("\(customMaxDurationSeconds) s")
                                    .font(.system(size: 11, design: .monospaced))
                            }
                            .controlSize(.small)
                        } else {
                            Text("\(appState.macroMaxTotalWaitSeconds) s")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }
            .padding(.top, 6)
        }
        .font(.caption.weight(.semibold))
        .padding(10)
        .background(Color.primary.opacity(0.04))
        .cornerRadius(8)
    }

    private func save() {
        let trimmedName = toolName.trimmingCharacters(in: .whitespacesAndNewlines)
        let primaryTarget = (actionType == .macro ? macroSteps.first?.target : nil) ?? target
        let schema = CustomMCPToolSchema(
            name: trimmedName,
            description: toolDescription.trimmingCharacters(in: .whitespacesAndNewlines),
            appPackageHint: existingTool?.appPackageHint,
            isEnabled: existingTool?.isEnabled ?? true,
            action: actionType,
            target: primaryTarget,
            parameters: parameters.map {
                CustomMCPParameter(
                    name: $0.name.trimmingCharacters(in: .whitespacesAndNewlines),
                    type: $0.type,
                    description: $0.description.trimmingCharacters(in: .whitespacesAndNewlines),
                    required: $0.required
                )
            },
            steps: actionType == .macro ? macroSteps : nil,
            defaultStepDelayMs: useCustomStepDelay ? customStepDelayMs : nil,
            maxSteps: useCustomMaxSteps ? customMaxSteps : nil,
            maxDurationSeconds: useCustomMaxDuration ? customMaxDurationSeconds : nil,
            selfHealingEnabled: useCustomSelfHealing ? customSelfHealingEnabled : nil,
            createdAt: existingTool?.createdAt ?? Date()
        )
        do {
            try CustomMCPToolRegistry.shared.saveTool(schema)
            onSaved(schema)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private enum CustomMCPToolSheetHelpers {
    static func extractAutoParameters(from steps: [VisualMacroStep]) -> [CustomMCPParameter] {
        var params: [CustomMCPParameter] = []
        var seen = Set<String>()
        for step in steps {
            if let tpl = step.textTemplate {
                for name in CustomMCPToolSchema.extractPlaceholderNames(from: tpl) where seen.insert(name).inserted {
                    params.append(
                        CustomMCPParameter(
                            name: name,
                            type: "string",
                            description: "Dynamic text substituted into {{\(name)}}",
                            required: true
                        )
                    )
                }
            }
        }
        return params
    }
}
