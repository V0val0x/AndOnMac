package com.shadowgraph.daemon.graph

/**
 * Represents an updated node together with a bitmask of which property groups changed.
 */
data class ShadowNodePatch(
    val node: ShadowNode,
    val mask: Int
)

/**
 * Result of comparing two [ShadowTreeSnapshot]s.
 */
sealed class TreeDiffResult {
    data object NoOp : TreeDiffResult()

    data class FullSnapshot(
        val snapshot: ShadowTreeSnapshot,
        val reason: String
    ) : TreeDiffResult()

    data class IncrementalDiff(
        val baseSeq: Long,
        val seq: Long,
        val timestampMs: Long,
        val activePackage: String,
        val activeWindowId: Int,
        val inserted: List<ShadowNode>,
        val updated: List<ShadowNodePatch>,
        val removedIds: List<Long>
    ) : TreeDiffResult()
}

/**
 * O(N) structural tree differ with reusable scratch lists to avoid steady-state allocations
 * on the worker thread.
 */
class ShadowTreeDiffer {
    private val insertedScratch = ArrayList<ShadowNode>(64)
    private val updatedScratch = ArrayList<ShadowNodePatch>(64)
    private val removedScratch = ArrayList<Long>(64)

    fun diff(
        previous: ShadowTreeSnapshot?,
        current: ShadowTreeSnapshot,
        forceSnapshot: Boolean = false
    ): TreeDiffResult {
        if (previous == null) {
            return TreeDiffResult.FullSnapshot(current, reason = "initial")
        }
        if (forceSnapshot) {
            return TreeDiffResult.FullSnapshot(current, reason = "requested")
        }
        if (previous.activePackage != current.activePackage) {
            return TreeDiffResult.FullSnapshot(current, reason = "package_switch")
        }
        if (previous.activeWindowId != current.activeWindowId) {
            return TreeDiffResult.FullSnapshot(current, reason = "window_switch")
        }

        insertedScratch.clear()
        updatedScratch.clear()
        removedScratch.clear()

        val prevById = previous.nodesById
        val currNodes = current.nodes
        for (i in 0 until currNodes.size) {
            val currNode = currNodes[i]
            val prevNode = prevById[currNode.nodeId]
            if (prevNode == null) {
                insertedScratch.add(currNode)
            } else {
                val mask = prevNode.diffMask(currNode)
                if (mask != 0) {
                    updatedScratch.add(ShadowNodePatch(currNode, mask))
                }
            }
        }

        val currById = current.nodesById
        val prevNodes = previous.nodes
        for (i in 0 until prevNodes.size) {
            val prevNode = prevNodes[i]
            if (!currById.containsKey(prevNode.nodeId)) {
                removedScratch.add(prevNode.nodeId)
            }
        }

        if (insertedScratch.isEmpty() && updatedScratch.isEmpty() && removedScratch.isEmpty()) {
            return TreeDiffResult.NoOp
        }

        return TreeDiffResult.IncrementalDiff(
            baseSeq = previous.seq,
            seq = current.seq,
            timestampMs = current.timestampMs,
            activePackage = current.activePackage,
            activeWindowId = current.activeWindowId,
            inserted = ArrayList(insertedScratch),
            updated = ArrayList(updatedScratch),
            removedIds = ArrayList(removedScratch)
        )
    }
}
