import SwiftUI
import AppKit

/// Freezes the current scrcpy frame and lets the user drag bounding boxes to turn Android UI elements into MCP tools.
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

                if let rect = activeSelectionRect(in: geo.size) {
                    Rectangle()
                        .fill(Color.green.opacity(0.16))
                        .overlay(
                            Rectangle()
                                .stroke(
                                    Color.green,
                                    style: StrokeStyle(lineWidth: 2, dash: [6, 4], dashPhase: dashPhase)
                                )
                        )
                        .shadow(color: .green.opacity(0.35), radius: 8)
                        .frame(width: rect.width, height: rect.height)
                        .position(x: rect.midX, y: rect.midY)
                }

                VStack {
                    HStack(spacing: 8) {
                        Image(systemName: isAnalyzing ? "cpu" : "square.dashed")
                            .symbolRenderingMode(.hierarchical)
                            .foregroundColor(.green)
                            .symbolEffect(.pulse, isActive: isAnalyzing)

                        Text(isAnalyzing
                             ? L10n.tr("Анализ Android UI...", "Mapping Android UI node...", lang: appState.lang)
                             : L10n.tr("Выделите элемент для MCP Tool", "Drag a box over a UI element", lang: appState.lang))
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.white)

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
                    .andonGlassCapsule(tintOpacity: 0.58)
                    .padding(.top, 14)

                    Spacer()
                }
            }
            .onAppear {
                if let cgImage = ScrcpyClient.shared.latestFrameImage {
                    frozenImage = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
                }
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
                        appState.photoTransferNotice = L10n.tr(
                            "MCP Tool '\(saved.name)' сохранён",
                            "Saved MCP Tool '\(saved.name)'",
                            lang: appState.lang
                        )
                        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                            appState.photoTransferNotice = nil
                        }
                    },
                    onCancel: {
                        matchedNode = nil
                        lastNormalizedRect = nil
                    }
                )
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
                matchedNode = matched
            }
        }
    }
}

private struct IdentifiableMatchedNode: Identifiable {
    let id = UUID()
    let node: MatchedVisualNode
}
