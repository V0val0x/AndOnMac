package com.shadowgraph.daemon.graph

/**
 * Immutable snapshot of the Android accessibility hierarchy at a single monotonic sequence point.
 */
class ShadowTreeSnapshot(
    val seq: Long,
    val timestampNs: Long,
    val timestampMs: Long,
    val activePackage: String,
    val activeWindowId: Int,
    val nodes: List<ShadowNode>,
    val nodesById: Map<Long, ShadowNode>
) {
    companion object {
        fun fromNodes(
            seq: Long,
            timestampNs: Long,
            timestampMs: Long,
            activePackage: String,
            activeWindowId: Int,
            nodes: List<ShadowNode>
        ): ShadowTreeSnapshot {
            val map = LinkedHashMap<Long, ShadowNode>(nodes.size * 2)
            for (i in 0 until nodes.size) {
                val node = nodes[i]
                map[node.nodeId] = node
            }
            return ShadowTreeSnapshot(
                seq = seq,
                timestampNs = timestampNs,
                timestampMs = timestampMs,
                activePackage = activePackage,
                activeWindowId = activeWindowId,
                nodes = nodes,
                nodesById = map
            )
        }
    }
}
