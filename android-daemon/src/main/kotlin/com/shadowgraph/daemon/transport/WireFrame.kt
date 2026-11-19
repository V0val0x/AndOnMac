package com.shadowgraph.daemon.transport

import com.shadowgraph.daemon.graph.ShadowTreeSnapshot
import com.shadowgraph.daemon.graph.TreeDiffResult

data class WireHello(
    val protocolVersion: Int,
    val format: String,
    val sdkInt: Int,
    val deviceModel: String,
    val daemonPid: Long,
    val capabilities: List<String> = emptyList()
)

data class WireSnapshot(
    val snapshot: ShadowTreeSnapshot,
    val reason: String
)

data class WireDiff(
    val diff: TreeDiffResult.IncrementalDiff,
    val eventType: Int? = null,
    val eventPackage: String? = null
)

data class WireHeartbeat(
    val seq: Long,
    val timestampMs: Long,
    val uptimeMs: Long,
    val activePackage: String,
    val activeWindowId: Int,
    val clientCount: Int
)

data class WireError(
    val code: String,
    val message: String,
    val timestampMs: Long
)

data class WirePong(
    val timestampMs: Long,
    val seq: Long
)

data class WireSecureScreen(
    val code: String,
    val active: Boolean,
    val reason: String,
    val activePackage: String,
    val timestampMs: Long
)

data class WireInputResult(
    val id: Long,
    val cmd: String,
    val ok: Boolean,
    val error: String? = null,
    val elapsedMs: Long,
    val timestampMs: Long
)

sealed class InboundCommand {
    data object Snapshot : InboundCommand()
    data object Ping : InboundCommand()
    data class SetDebounce(val debounceMs: Long) : InboundCommand()
    data object Shutdown : InboundCommand()
    data class Tap(val id: Long, val x: Int, val y: Int) : InboundCommand()
    data class Swipe(
        val id: Long,
        val x1: Int,
        val y1: Int,
        val x2: Int,
        val y2: Int,
        val durationMs: Long,
        val holdMs: Long
    ) : InboundCommand()
    data class Keyevent(val id: Long, val keycode: Int) : InboundCommand()
    data class Unknown(val raw: String, val reason: String) : InboundCommand()
}
