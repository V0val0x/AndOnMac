import Foundation

public struct HazardousConfirmationRequest: Sendable, Codable, Equatable {
    public let stepIndex: Int
    public let totalSteps: Int
    public let actionSignature: String
    public let targetDescription: String
    public let hazardCategory: HazardCategory
    public let hazardReason: String
    public let currentHash: UInt64
    public let targetHash: UInt64
    public let stepsCompleted: Int
    public let tapX: Int?
    public let tapY: Int?

    public init(
        stepIndex: Int,
        totalSteps: Int,
        actionSignature: String,
        targetDescription: String,
        hazardCategory: HazardCategory,
        hazardReason: String,
        currentHash: UInt64,
        targetHash: UInt64,
        stepsCompleted: Int,
        tapX: Int? = nil,
        tapY: Int? = nil
    ) {
        self.stepIndex = stepIndex
        self.totalSteps = totalSteps
        self.actionSignature = actionSignature
        self.targetDescription = targetDescription
        self.hazardCategory = hazardCategory
        self.hazardReason = hazardReason
        self.currentHash = currentHash
        self.targetHash = targetHash
        self.stepsCompleted = stepsCompleted
        self.tapX = tapX
        self.tapY = tapY
    }
}

public enum PathDeviationError: Error, Sendable, Equatable, CustomStringConvertible, LocalizedError {
    case executionAlreadyInProgress
    case shadowStreamUnavailable
    case missingActionPayload(stepIndex: Int, edgeId: UUID)
    case unexpectedStartState(expectedHash: UInt64, actualHash: UInt64?, actualPackage: String)
    case actionDispatchFailed(stepIndex: Int, actionSignature: String, underlyingMessage: String)
    case stepTimeout(
        stepIndex: Int,
        expectedTargetHash: UInt64,
        lastObservedHash: UInt64?,
        lastObservedPackage: String,
        timeoutMs: Int
    )
    case requiresConfirmation(HazardousConfirmationRequest)
    case secureScreenTimeout(reason: String, activePackage: String, timeoutSeconds: Int)

    public var description: String {
        switch self {
        case .executionAlreadyInProgress:
            return "A macro execution is already in progress."
        case .shadowStreamUnavailable:
            return "Shadow DOM state is unavailable; cannot verify live screen."
        case .missingActionPayload(let stepIndex, let edgeId):
            return "Transition edge \(edgeId) at step \(stepIndex) has no executable UI action."
        case .unexpectedStartState(let expectedHash, let actualHash, let actualPackage):
            let expectedHex = String(format: "0x%016llx", expectedHash)
            let actualHex = actualHash.map { String(format: "0x%016llx", $0) } ?? "nil"
            return "Unexpected start state: expected \(expectedHex), observed \(actualHex) (package: \(actualPackage))."
        case .actionDispatchFailed(let stepIndex, let actionSignature, let underlyingMessage):
            return "Failed to dispatch '\(actionSignature)' at step \(stepIndex): \(underlyingMessage)"
        case .stepTimeout(let stepIndex, let expectedTargetHash, let lastObservedHash, let lastObservedPackage, let timeoutMs):
            let expectedHex = String(format: "0x%016llx", expectedTargetHash)
            let actualHex = lastObservedHash.map { String(format: "0x%016llx", $0) } ?? "nil"
            return "Path deviation at step \(stepIndex): ShadowDOM did not settle into \(expectedHex) within \(timeoutMs)ms (last observed: \(actualHex), package: \(lastObservedPackage))."
        case .requiresConfirmation(let req):
            return "Human confirmation required before executing '\(req.actionSignature)' at step \(req.stepIndex + 1)/\(req.totalSteps): \(req.hazardReason)."
        case .secureScreenTimeout(let reason, let activePackage, let timeoutSeconds):
            return "Secure/biometric screen (\(reason) in \(activePackage)) remained locked past \(timeoutSeconds)s handoff timeout."
        }
    }

    public var errorDescription: String? {
        description
    }
}

/// Host-agnostic UI action injector implemented by `StandaloneADBAutomationDriver`, `ADBService`, or unit test mocks.
public protocol MacroActionExecutor: Sendable {
    func execute(action: AttributedUIAction, serial: String) async throws
}

public struct MacroExecutionConfiguration: Sendable, Equatable {
    public let stepTimeoutMs: Int
    public let postSettleQuiescenceMs: Int
    public let settleSimilarityThreshold: Double
    public let allowHazardousActions: Bool
    public let enableForwardSkipRecovery: Bool
    public let enableOverlaySwipeDismiss: Bool
    public let secureHandoffTimeoutSeconds: TimeInterval

    public init(
        stepTimeoutMs: Int = 2000,
        postSettleQuiescenceMs: Int = 40,
        settleSimilarityThreshold: Double = 0.80,
        allowHazardousActions: Bool = false,
        enableForwardSkipRecovery: Bool = true,
        enableOverlaySwipeDismiss: Bool = true,
        secureHandoffTimeoutSeconds: TimeInterval = 60.0
    ) {
        self.stepTimeoutMs = max(50, stepTimeoutMs)
        self.postSettleQuiescenceMs = max(0, postSettleQuiescenceMs)
        self.settleSimilarityThreshold = max(0.0, min(1.0, settleSimilarityThreshold))
        self.allowHazardousActions = allowHazardousActions
        self.enableForwardSkipRecovery = enableForwardSkipRecovery
        self.enableOverlaySwipeDismiss = enableOverlaySwipeDismiss
        self.secureHandoffTimeoutSeconds = max(0.5, secureHandoffTimeoutSeconds)
    }
}

public struct MacroStepReport: Sendable, Codable, Equatable {
    public let stepIndex: Int
    public let edgeId: UUID
    public let actionSignature: String
    public let targetHash: UInt64
    public let elapsedMs: Int
    public let matchedByExactHash: Bool
    public let wasSkipped: Bool

    public init(
        stepIndex: Int,
        edgeId: UUID,
        actionSignature: String,
        targetHash: UInt64,
        elapsedMs: Int,
        matchedByExactHash: Bool,
        wasSkipped: Bool = false
    ) {
        self.stepIndex = stepIndex
        self.edgeId = edgeId
        self.actionSignature = actionSignature
        self.targetHash = targetHash
        self.elapsedMs = elapsedMs
        self.matchedByExactHash = matchedByExactHash
        self.wasSkipped = wasSkipped
    }
}

public struct MacroExecutionReport: Sendable, Codable, Equatable {
    public let startHash: UInt64
    public let finalHash: UInt64
    public let steps: [MacroStepReport]
    public let totalElapsedMs: Int
    public let recoveredSteps: [String]

    public enum CodingKeys: String, CodingKey {
        case startHash
        case finalHash
        case steps
        case totalElapsedMs
        case recoveredSteps
    }

    public init(
        startHash: UInt64,
        finalHash: UInt64,
        steps: [MacroStepReport],
        totalElapsedMs: Int,
        recoveredSteps: [String] = []
    ) {
        self.startHash = startHash
        self.finalHash = finalHash
        self.steps = steps
        self.totalElapsedMs = totalElapsedMs
        self.recoveredSteps = recoveredSteps
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.startHash = try container.decode(UInt64.self, forKey: .startHash)
        self.finalHash = try container.decode(UInt64.self, forKey: .finalHash)
        self.steps = try container.decode([MacroStepReport].self, forKey: .steps)
        self.totalElapsedMs = try container.decode(Int.self, forKey: .totalElapsedMs)
        self.recoveredSteps = try container.decodeIfPresent([String].self, forKey: .recoveredSteps) ?? []
    }
}

public enum MacroExecutionEvent: Sendable, Equatable {
    case pathComputed(totalSteps: Int, targetHint: String?)
    case executionStarted(totalSteps: Int)
    case willExecuteAction(stepIndex: Int, totalSteps: Int, action: AttributedUIAction)
    case stepSettled(stepIndex: Int, totalSteps: Int, report: MacroStepReport)
    case completed(report: MacroExecutionReport)
    case failed(message: String)
    case awaitingConfirmation(stepIndex: Int, totalSteps: Int, action: AttributedUIAction, reason: String)
    case awaitingChatInput(prompt: String, focusX: Int?, focusY: Int?)
    case awaitingBiometrics(reason: String, activePackage: String)
    case biometricsCleared
    case recoveryAction(kind: String, detail: String)
}
