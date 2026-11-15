import SwiftUI
import AppKit

/// Interactive selection rectangle overlay on the mirror screen for on-device Apple Vision OCR (`Cmd+Shift+X`).
public struct ScreenOCROverlayView: View {
    @ObservedObject var appState: AppState
    @State private var dragStart: CGPoint? = nil
    @State private var dragCurrent: CGPoint? = nil
    @State private var isProcessing: Bool = false
    @State private var dashPhase: CGFloat = 0
    @State private var isHovering: Bool = false

    public init(appState: AppState) {
        self.appState = appState
    }

    public var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black.opacity(0.36)
                    .contentShape(Rectangle())

                if let rect = currentSelectionRect(in: geo.size) {
                    Rectangle()
                        .fill(Color.cyan.opacity(0.16))
                        .overlay(
                            Rectangle()
                                .stroke(
                                    Color.cyan,
                                    style: StrokeStyle(lineWidth: 2, dash: [6, 4], dashPhase: dashPhase)
                                )
                        )
                        .shadow(color: .cyan.opacity(0.35), radius: 8)
                        .frame(width: rect.width, height: rect.height)
                        .position(x: rect.midX, y: rect.midY)
                        .transition(.scale(scale: 0.96).combined(with: .opacity))
                }

                VStack {
                    HStack(spacing: 8) {
                        Image(systemName: isProcessing ? "sparkles" : "text.viewfinder")
                            .symbolRenderingMode(.hierarchical)
                            .foregroundColor(.cyan)
                            .symbolEffect(.pulse, isActive: isProcessing)
                        Text(isProcessing
                             ? L10n.tr("Распознавание...", "Recognizing...", lang: appState.lang)
                             : L10n.tr("Выделите область с текстом", "Drag over text to copy", lang: appState.lang))
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.white)

                        Button {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                appState.isOCROverlayActive = false
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
                    .andonGlassCapsule(tintOpacity: 0.55)
                    .padding(.top, 14)

                    Spacer()
                }
            }
            .onAppear {
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
                        if dragStart == nil { dragStart = value.startLocation }
                        dragCurrent = value.location
                    }
                    .onEnded { value in
                        guard let start = dragStart else { return }
                        let rect = normalizedRect(from: start, to: value.location, in: geo.size)
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                            dragStart = nil
                            dragCurrent = nil
                        }
                        runOCR(normalizedRect: rect)
                    }
            )
        }
    }

    private func currentSelectionRect(in size: CGSize) -> CGRect? {
        guard let start = dragStart, let current = dragCurrent else { return nil }
        return CGRect(
            x: min(start.x, current.x),
            y: min(start.y, current.y),
            width: abs(current.x - start.x),
            height: abs(current.y - start.y)
        )
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

    private func runOCR(normalizedRect: CGRect) {
        isProcessing = true
        Task {
            do {
                let text = try await VisionOCRService.shared.grabTextFromMirrorFrame(normalizedCropRect: normalizedRect)
                await MainActor.run {
                    isProcessing = false
                    appState.isOCROverlayActive = false
                    if text.isEmpty {
                        appState.photoTransferNotice = L10n.tr("Текст не найден", "No text found", lang: appState.lang)
                    } else {
                        let preview = text.count > 42 ? String(text.prefix(42)) + "..." : text
                        appState.photoTransferNotice = L10n.tr("Скопировано: \(preview)", "Copied: \(preview)", lang: appState.lang)
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                        appState.photoTransferNotice = nil
                    }
                }
            } catch {
                await MainActor.run {
                    isProcessing = false
                    appState.isOCROverlayActive = false
                    appState.photoTransferNotice = L10n.tr("Ошибка OCR", "OCR failed", lang: appState.lang)
                }
            }
        }
    }
}
