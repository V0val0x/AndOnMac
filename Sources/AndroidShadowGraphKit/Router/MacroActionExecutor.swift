import Foundation

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

    public init(
        stepTimeoutMs: Int = 2000,
        postSettleQuiescenceMs: Int = 40,
        settleSimilarityThreshold: Double = 0.80
    ) {
        self.stepTimeoutMs = max(50, stepTimeoutMs)
        self.postSettleQuiescenceMs = max(0, postSettleQuiescenceMs)
        self.settleSimilarityThreshold = max(0.0, min(1.0, settleSimilarityThreshold))
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

    public init(
        startHash: UInt64,
        finalHash: UInt64,
        steps: [MacroStepReport],
        totalElapsedMs: Int
    ) {
        self.startHash = startHash
        self.finalHash = finalHash
        self.steps = steps
        self.totalElapsedMs = totalElapsedMs
    }
}

public enum MacroExecutionEvent: Sendable, Equatable {
    case pathComputed(totalSteps: Int, targetHint: String?)
    case executionStarted(totalSteps: Int)
    case willExecuteAction(stepIndex: Int, totalSteps: Int, action: AttributedUIAction)
    case stepSettled(stepIndex: Int, totalSteps: Int, report: MacroStepReport)
    case completed(report: MacroExecutionReport)
    case failed(message: String)
}
