import SwiftUI
import AppKit

/// Freezes the current scrcpy frame and lets the user capture single visual MCP tools OR record multi-step semantic macros.
public struct VisualMCPCaptureOverlayView: View {
    @ObservedObject var appState: AppState
    @State private var frozenImage: NSImage? = nil
    @State private var dragStart: CGPoint? = nil
    @State private var dragCurrent: CGPoint? = nil
    @State private var lastNormalizedRect: CGRect? = nil
    @State private var isAnalyzing: Bool = false
    @State private var matchedNode: MatchedVisualNode? = nil
    @State private var dashPhase: CGFloat = 0
    @State private var isHovering: Bool = false

    // Multi-step Semantic Macro Recorder state
    @State private var isRecordingMacro: Bool = false
    @State private var recordedSteps: [VisualMacroStep] = []
    @State private var pendingMacroStepNode: MatchedVisualNode? = nil
    @State private var showMacroSaveSheet: Bool = false

    public init(appState: AppState) {
        self.appState = appState
    }

    public var body: some View {
        GeometryReader { geo in
            ZStack {
                if let frozenImage {
                    Image(nsImage: frozenImage)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                }

                Color.black.opacity(0.32)
                    .contentShape(Rectangle())

                // Recorded step badges on overlay
                if isRecordingMacro {
                    ForEach(Array(recordedSteps.enumerated()), id: \.element.id) { index, step in
                        let norm = step.target.cgNormalizedRect
                        let cx = norm.midX * geo.size.width
                        let cy = norm.midY * geo.size.height
                        Text("\(index + 1)")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundColor(.white)
                            .frame(width: 20, height: 20)
                            .background(Circle().fill(Color.red.opacity(0.9)))
                            .overlay(Circle().stroke(Color.white, lineWidth: 1))
                            .position(x: cx, y: cy)
                    }
                }

                if let rect = activeSelectionRect(in: geo.size) {
                    let accent: Color = isRecordingMacro ? .red : .green
                    Rectangle()
                        .fill(accent.opacity(0.16))
                        .overlay(
                            Rectangle()
                                .stroke(
                                    accent,
                                    style: StrokeStyle(lineWidth: 2, dash: [6, 4], dashPhase: dashPhase)
                                )
                        )
                        .shadow(color: accent.opacity(0.35), radius: 8)
                        .frame(width: rect.width, height: rect.height)
                        .position(x: rect.midX, y: rect.midY)
                }

                VStack(spacing: 6) {
                    HStack(spacing: 8) {
                        Image(systemName: isAnalyzing ? "cpu" : (isRecordingMacro ? "record.circle.fill" : "square.dashed"))
                            .symbolRenderingMode(.hierarchical)
                            .foregroundColor(isRecordingMacro ? .red : .green)
                            .symbolEffect(.pulse, isActive: isAnalyzing || isRecordingMacro)

                        Text(headerTitle)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.white)
                            .lineLimit(1)

                        Button {
                            captureFreshFrame()
                        } label: {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundColor(.white.opacity(0.85))
                        }
                        .buttonStyle(.plain)
                        .help(L10n.tr("Обновить кадр экрана", "Refresh screen snapshot", lang: appState.lang))

                        Button {
                            withAnimation(AndMotion.hudSpring) {
                                appState.isVisualMCPCaptureActive = false
                            }
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .symbolRenderingMode(.hierarchical)
                                .foregroundColor(.white.opacity(0.75))
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .andonGlassCapsule(tintOpacity: 0.62)

                    // Macro Recorder Control Pill
                    HStack(spacing: 8) {
                        if !isRecordingMacro {
                            Button {
                                isRecordingMacro = true
                                recordedSteps = []
                                lastNormalizedRect = nil
                            } label: {
                                Label(
                                    L10n.tr("Записать макрос", "Record Macro", lang: appState.lang),
                                    systemImage: "record.circle"
                                )
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundColor(.white)
                            }
                            .buttonStyle(.plain)
                        } else {
                            Text("REC • \(recordedSteps.count)")
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .foregroundColor(.red)

                            if !recordedSteps.isEmpty {
                                Button {
                                    recordedSteps.removeLast()
                                } label: {
                                    Image(systemName: "arrow.uturn.backward")
                                        .font(.system(size: 10))
                                        .foregroundColor(.white.opacity(0.85))
                                }
                                .buttonStyle(.plain)
                                .help(L10n.tr("Удалить последний шаг", "Undo last step", lang: appState.lang))

                                Button {
                                    showMacroSaveSheet = true
                                } label: {
                                    Label(
                                        L10n.tr("Стоп и сохранить", "Stop & Save", lang: appState.lang),
                                        systemImage: "stop.circle.fill"
                                    )
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundColor(.green)
                                }
                                .buttonStyle(.plain)
                            } else {
                                Button {
                                    isRecordingMacro = false
                                } label: {
                                    Text(L10n.tr("Отмена", "Cancel Macro", lang: appState.lang))
                                        .font(.system(size: 10, weight: .medium))
                                        .foregroundColor(.white.opacity(0.8))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .padding(.horizontal, 11)
                    .padding(.vertical, 5)
                    .andonGlassCapsule(tintOpacity: 0.56)

                    Spacer()
                }
                .padding(.top, 14)
            }
            .onAppear {
                captureFreshFrame()
                withAnimation(.linear(duration: 0.8).repeatForever(autoreverses: false)) {
                    dashPhase = -20
                }
            }
            .onHover { hovering in
                if hovering && !isHovering {
                    isHovering = true
                    NSCursor.crosshair.push()
                } else if !hovering && isHovering {
                    isHovering = false
                    NSCursor.pop()
                }
            }
            .onDisappear {
                if isHovering {
                    isHovering = false
                    NSCursor.pop()
                }
            }
            .gesture(
                DragGesture(minimumDistance: 4)
                    .onChanged { value in
                        guard !isAnalyzing else { return }
                        if dragStart == nil { dragStart = value.startLocation }
                        dragCurrent = value.location
                    }
                    .onEnded { value in
                        guard !isAnalyzing, let start = dragStart else { return }
                        let rect = normalizedRect(from: start, to: value.location, in: geo.size)
                        lastNormalizedRect = rect
                        dragStart = nil
                        dragCurrent = nil
                        analyzeSelection(normalizedRect: rect)
                    }
            )
            // Single-action sheet
            .sheet(item: Binding(
                get: { matchedNode.map { IdentifiableMatchedNode(node: $0) } },
                set: { if $0 == nil { matchedNode = nil } }
            )) { wrapper in
                VisualMCPToolSheet(
                    appState: appState,
                    matchedNode: wrapper.node,
                    onSaved: { saved in
                        matchedNode = nil
                        lastNormalizedRect = nil
                        appState.isVisualMCPCaptureActive = false
                        showSavedNotice(saved.name)
                    },
                    onCancel: {
                        matchedNode = nil
                        lastNormalizedRect = nil
                    }
                )
            }
            // Macro step composer sheet
            .sheet(item: Binding(
                get: { pendingMacroStepNode.map { IdentifiableMatchedNode(node: $0) } },
                set: { if $0 == nil { pendingMacroStepNode = nil } }
            )) { wrapper in
                MacroStepComposerSheet(
                    appState: appState,
                    matchedNode: wrapper.node,
                    stepNumber: recordedSteps.count + 1,
                    onAddStep: { step, runLiveOnPhone in
                        recordedSteps.append(step)
                        pendingMacroStepNode = nil
                        lastNormalizedRect = nil
                        if runLiveOnPhone {
                            executeLiveStepAndRefresh(step)
                        }
                    },
                    onCancel: {
                        pendingMacroStepNode = nil
                        lastNormalizedRect = nil
                    }
                )
            }
            // Finalize recorded macro sheet
            .sheet(isPresented: $showMacroSaveSheet) {
                VisualMCPToolSheet(
                    appState: appState,
                    macroSteps: recordedSteps,
                    onSaved: { saved in
                        showMacroSaveSheet = false
                        isRecordingMacro = false
                        recordedSteps = []
                        lastNormalizedRect = nil
                        appState.isVisualMCPCaptureActive = false
                        showSavedNotice(saved.name)
                    },
                    onCancel: {
                        showMacroSaveSheet = false
                    }
                )
            }
        }
    }

    private var headerTitle: String {
        if isAnalyzing {
            return L10n.tr("Анализ Android UI...", "Mapping Android UI node...", lang: appState.lang)
        }
        if isRecordingMacro {
            return L10n.tr("Шаг \(recordedSteps.count + 1): выделите элемент", "Step \(recordedSteps.count + 1): drag over UI element", lang: appState.lang)
        }
        return L10n.tr("Выделите элемент для MCP Tool", "Drag a box over a UI element", lang: appState.lang)
    }

    private func captureFreshFrame() {
        if let cgImage = ScrcpyClient.shared.latestFrameImage {
            frozenImage = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        }
    }

    private func showSavedNotice(_ name: String) {
        appState.photoTransferNotice = L10n.tr(
            "MCP Tool '\(name)' сохранён",
            "Saved MCP Tool '\(name)'",
            lang: appState.lang
        )
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
            appState.photoTransferNotice = nil
        }
    }

    private func executeLiveStepAndRefresh(_ step: VisualMacroStep) {
        let serialHint = appState.selectedDevice?.id
        let waitMs = step.delayAfterMs ?? appState.macroDefaultStepDelayMs
        Task {
            guard let serial = try? await AndroidMCPTools.resolveSerial(serialHint) else { return }
            if step.action == .tapElement || step.action == .typeText {
                _ = try? await ADBService.shared.execute(
                    arguments: ["-s", serial, "shell", "input", "tap", "\(step.target.fallbackX)", "\(step.target.fallbackY)"],
                    timeoutSeconds: 4.0
                )
            }
            if step.action == .typeText, let tpl = step.textTemplate, !tpl.isEmpty, !tpl.contains("{{") {
                let cmd = AndroidMCPTools.buildSafeTypeTextCommand(tpl)
                if cmd.useClipboard {
                    _ = try? await ADBService.shared.execute(
                        arguments: ["-s", serial, "shell", "cmd", "clipboard", "set", "text", cmd.quotedArg],
                        timeoutSeconds: 3.0
                    )
                    _ = try? await ADBService.shared.execute(
                        arguments: ["-s", serial, "shell", "input", "keyevent", "279"],
                        timeoutSeconds: 3.0
                    )
                } else {
                    _ = try? await ADBService.shared.execute(
                        arguments: ["-s", serial, "shell", "input", "text", cmd.quotedArg],
                        timeoutSeconds: 4.0
                    )
                }
            }
            let totalWait = max(250, min(2000, waitMs))
            try? await Task.sleep(nanoseconds: UInt64(totalWait) * 1_000_000)
            await MainActor.run {
                captureFreshFrame()
            }
        }
    }

    private func activeSelectionRect(in size: CGSize) -> CGRect? {
        if let start = dragStart, let current = dragCurrent {
            return CGRect(
                x: min(start.x, current.x),
                y: min(start.y, current.y),
                width: abs(current.x - start.x),
                height: abs(current.y - start.y)
            )
        }
        if let norm = lastNormalizedRect {
            return CGRect(
                x: norm.origin.x * size.width,
                y: norm.origin.y * size.height,
                width: norm.size.width * size.width,
                height: norm.size.height * size.height
            )
        }
        return nil
    }

    private func normalizedRect(from start: CGPoint, to end: CGPoint, in size: CGSize) -> CGRect {
        let w = max(1, size.width)
        let h = max(1, size.height)
        let minX = max(0, min(start.x, end.x)) / w
        let minY = max(0, min(start.y, end.y)) / h
        let width = min(1 - minX, abs(end.x - start.x) / w)
        let height = min(1 - minY, abs(end.y - start.y) / h)
        return CGRect(x: minX, y: minY, width: max(0.02, width), height: max(0.02, height))
    }

    private func analyzeSelection(normalizedRect: CGRect) {
        isAnalyzing = true
        let serialHint = appState.selectedDevice?.id
        let fallbackW = max(1, Int(frozenImage?.size.width ?? 1080))
        let fallbackH = max(1, Int(frozenImage?.size.height ?? 2400))

        Task {
            let nodes: [AndroidUINode]
            if let serial = try? await AndroidMCPTools.resolveSerial(serialHint) {
                nodes = (try? await AndroidMCPTools.fetchUITree(serial: serial)) ?? []
            } else {
                nodes = []
            }

            let deviceW = ScrcpyClient.shared.deviceWidth > 0 ? ScrcpyClient.shared.deviceWidth : fallbackW
            let deviceH = ScrcpyClient.shared.deviceHeight > 0 ? ScrcpyClient.shared.deviceHeight : fallbackH

            let matched = VisualNodeMatcher.matchBestNode(
                normalizedRect: normalizedRect,
                deviceWidth: deviceW,
                deviceHeight: deviceH,
                nodes: nodes
            )

            await MainActor.run {
                isAnalyzing = false
                if isRecordingMacro {
                    pendingMacroStepNode = matched
                } else {
                    matchedNode = matched
                }
            }
        }
    }
}

private struct MacroStepComposerSheet: View {
    @ObservedObject var appState: AppState
    let matchedNode: MatchedVisualNode
    let stepNumber: Int
    let onAddStep: (VisualMacroStep, Bool) -> Void
    let onCancel: () -> Void

    @State private var actionType: VisualMCPActionType = .tapElement
    @State private var textTemplate: String = "{{message_body}}"
    @State private var delayAfterMs: Int
    @State private var runLiveOnPhone: Bool = true

    init(
        appState: AppState,
        matchedNode: MatchedVisualNode,
        stepNumber: Int,
        onAddStep: @escaping (VisualMacroStep, Bool) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.appState = appState
        self.matchedNode = matchedNode
        self.stepNumber = stepNumber
        self.onAddStep = onAddStep
        self.onCancel = onCancel
        _delayAfterMs = State(initialValue: appState.macroDefaultStepDelayMs)
    }

    private var lang: AppLanguage { appState.lang }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "record.circle.fill")
                    .foregroundColor(.red)
                Text(L10n.tr("Добавить шаг #\(stepNumber)", "Add Macro Step #\(stepNumber)", lang: lang))
                    .font(.headline)
                Spacer()
                Button(L10n.tr("Отмена", "Cancel", lang: lang)) {
                    onCancel()
                }
                .keyboardShortcut(.cancelAction)
            }

            if let node = matchedNode.node {
                Text(node.resource_id.isEmpty ? (node.text.isEmpty ? node.class : node.text) : node.resource_id)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } else {
                Text("coords: (\(matchedNode.fallbackCenterX), \(matchedNode.fallbackCenterY))")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.orange)
            }

            Picker(L10n.tr("Действие", "Action", lang: lang), selection: $actionType) {
                ForEach(VisualMCPActionType.singleStepCases) { action in
                    Text(action.localizedTitle(lang: lang)).tag(action)
                }
            }

            if actionType == .typeText {
                VStack(alignment: .leading, spacing: 6) {
                    Text(L10n.tr("Текст или {{параметр}} для LLM", "Text or Dynamic {{parameter}}", lang: lang))
                        .font(.caption.weight(.semibold))
                    TextField("{{message_body}}", text: $textTemplate)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))

                    HStack(spacing: 6) {
                        ForEach(["{{message_body}}", "{{contact_name}}", "{{query}}"], id: \.self) { chip in
                            Button(chip) {
                                textTemplate = chip
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.mini)
                        }
                    }
                }
            }

            Stepper(
                value: $delayAfterMs,
                in: 0...MCPExecutionDefaults.maxStepDelayMs,
                step: 50
            ) {
                HStack {
                    Text(L10n.tr("Пауза после шага", "Wait After Step", lang: lang))
                    Spacer()
                    Text("\(delayAfterMs) ms")
                        .font(.system(size: 11, design: .monospaced))
                }
            }

            Toggle(
                L10n.tr("Выполнить на телефоне и обновить кадр", "Run step on phone & advance snapshot", lang: lang),
                isOn: $runLiveOnPhone
            )
            .font(.caption)

            HStack {
                Spacer()
                Button(L10n.tr("Добавить шаг", "Add Step", lang: lang)) {
                    let step = VisualMacroStep(
                        action: actionType,
                        target: matchedNode.toVisualNodeTarget(),
                        textTemplate: actionType == .typeText ? textTemplate : nil,
                        delayAfterMs: delayAfterMs
                    )
                    onAddStep(step, runLiveOnPhone)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 400)
        .onAppear {
            if let node = matchedNode.node, node.class.localizedCaseInsensitiveContains("EditText") {
                actionType = .typeText
            }
        }
    }
}

private struct IdentifiableMatchedNode: Identifiable {
    let id = UUID()
    let node: MatchedVisualNode
}
