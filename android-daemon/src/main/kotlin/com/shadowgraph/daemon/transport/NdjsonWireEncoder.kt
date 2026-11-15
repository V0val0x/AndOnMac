package com.shadowgraph.daemon.transport

import com.shadowgraph.daemon.graph.ShadowNode
import com.shadowgraph.daemon.graph.ShadowNodePatch

/**
 * Line-Delimited JSON (NDJSON) implementation of [WireEncoder].
 * Serializes directly into [ByteArrayBuffer] with zero intermediate String/JSONObject allocations.
 */
class NdjsonWireEncoder : WireEncoder {
    override val formatName: String = "ndjson/1"

    override fun encodeHello(hello: WireHello, out: ByteArrayBuffer) {
        out.reset()
        out.appendAscii("{\"type\":\"hello\",\"protocol_version\":")
        out.appendInt(hello.protocolVersion)
        out.appendAscii(",\"format\":")
        out.appendJsonString(hello.format)
        out.appendAscii(",\"sdk_int\":")
        out.appendInt(hello.sdkInt)
        out.appendAscii(",\"device_model\":")
        out.appendJsonString(hello.deviceModel)
        out.appendAscii(",\"pid\":")
        out.appendLong(hello.daemonPid)
        out.appendAscii("}\n")
    }

    override fun encodeSnapshot(snapshot: WireSnapshot, out: ByteArrayBuffer) {
        val s = snapshot.snapshot
        out.reset()
        out.appendAscii("{\"type\":\"snapshot\",\"seq\":")
        out.appendLong(s.seq)
        out.appendAscii(",\"ts_ms\":")
        out.appendLong(s.timestampMs)
        out.appendAscii(",\"reason\":")
        out.appendJsonString(snapshot.reason)
        out.appendAscii(",\"package\":")
        out.appendJsonString(s.activePackage)
        out.appendAscii(",\"window_id\":")
        out.appendInt(s.activeWindowId)
        out.appendAscii(",\"node_count\":")
        out.appendInt(s.nodes.size)
        out.appendAscii(",\"nodes\":[")
        val nodes = s.nodes
        for (i in 0 until nodes.size) {
            if (i > 0) out.appendByte(','.code)
            appendFullNode(nodes[i], out)
        }
        out.appendAscii("]}\n")
    }

    override fun encodeDiff(diff: WireDiff, out: ByteArrayBuffer) {
        val d = diff.diff
        out.reset()
        out.appendAscii("{\"type\":\"diff\",\"base_seq\":")
        out.appendLong(d.baseSeq)
        out.appendAscii(",\"seq\":")
        out.appendLong(d.seq)
        out.appendAscii(",\"ts_ms\":")
        out.appendLong(d.timestampMs)
        out.appendAscii(",\"package\":")
        out.appendJsonString(d.activePackage)
        out.appendAscii(",\"window_id\":")
        out.appendInt(d.activeWindowId)
        if (diff.eventType != null) {
            out.appendAscii(",\"event_type\":")
            out.appendInt(diff.eventType)
        }
        if (diff.eventPackage != null) {
            out.appendAscii(",\"event_package\":")
            out.appendJsonString(diff.eventPackage)
        }
        out.appendAscii(",\"inserted\":[")
        val inserted = d.inserted
        for (i in 0 until inserted.size) {
            if (i > 0) out.appendByte(','.code)
            appendFullNode(inserted[i], out)
        }
        out.appendAscii("],\"updated\":[")
        val updated = d.updated
        for (i in 0 until updated.size) {
            if (i > 0) out.appendByte(','.code)
            appendNodePatch(updated[i], out)
        }
        out.appendAscii("],\"removed\":[")
        val removed = d.removedIds
        for (i in 0 until removed.size) {
            if (i > 0) out.appendByte(','.code)
            out.appendLong(removed[i])
        }
        out.appendAscii("]}\n")
    }

    override fun encodeHeartbeat(heartbeat: WireHeartbeat, out: ByteArrayBuffer) {
        out.reset()
        out.appendAscii("{\"type\":\"heartbeat\",\"seq\":")
        out.appendLong(heartbeat.seq)
        out.appendAscii(",\"ts_ms\":")
        out.appendLong(heartbeat.timestampMs)
        out.appendAscii(",\"uptime_ms\":")
        out.appendLong(heartbeat.uptimeMs)
        out.appendAscii(",\"package\":")
        out.appendJsonString(heartbeat.activePackage)
        out.appendAscii(",\"window_id\":")
        out.appendInt(heartbeat.activeWindowId)
        out.appendAscii(",\"clients\":")
        out.appendInt(heartbeat.clientCount)
        out.appendAscii("}\n")
    }

    override fun encodeError(error: WireError, out: ByteArrayBuffer) {
        out.reset()
        out.appendAscii("{\"type\":\"error\",\"code\":")
        out.appendJsonString(error.code)
        out.appendAscii(",\"message\":")
        out.appendJsonString(error.message)
        out.appendAscii(",\"ts_ms\":")
        out.appendLong(error.timestampMs)
        out.appendAscii("}\n")
    }

    override fun encodePong(pong: WirePong, out: ByteArrayBuffer) {
        out.reset()
        out.appendAscii("{\"type\":\"pong\",\"ts_ms\":")
        out.appendLong(pong.timestampMs)
        out.appendAscii(",\"seq\":")
        out.appendLong(pong.seq)
        out.appendAscii("}\n")
    }

    private fun appendFullNode(node: ShadowNode, out: ByteArrayBuffer) {
        out.appendAscii("{\"index\":")
        out.appendInt(node.index)
        out.appendAscii(",\"text\":")
        out.appendJsonString(node.text)
        out.appendAscii(",\"resource_id\":")
        out.appendJsonString(node.resourceId)
        out.appendAscii(",\"content_desc\":")
        out.appendJsonString(node.contentDesc)
        out.appendAscii(",\"class\":")
        out.appendJsonString(node.className)
        out.appendAscii(",\"clickable\":")
        out.appendBoolean(node.clickable)
        out.appendAscii(",\"scrollable\":")
        out.appendBoolean(node.scrollable)
        out.appendAscii(",\"bounds\":")
        appendBoundsString(node, out)
        out.appendAscii(",\"center_x\":")
        out.appendInt(node.centerX)
        out.appendAscii(",\"center_y\":")
        out.appendInt(node.centerY)
        out.appendAscii(",\"node_id\":")
        out.appendLong(node.nodeId)
        out.appendAscii(",\"parent_id\":")
        if (node.parentId == null) {
            out.appendAscii("null")
        } else {
            out.appendLong(node.parentId)
        }
        out.appendAscii(",\"window_id\":")
        out.appendInt(node.windowId)
        out.appendAscii(",\"child_index\":")
        out.appendInt(node.childIndex)
        out.appendAscii(",\"depth\":")
        out.appendInt(node.depth)
        out.appendAscii(",\"package_name\":")
        out.appendJsonString(node.packageName)
        out.appendAscii(",\"editable\":")
        out.appendBoolean(node.editable)
        out.appendAscii(",\"focused\":")
        out.appendBoolean(node.focused)
        out.appendAscii(",\"checked\":")
        out.appendBoolean(node.checked)
        out.appendAscii(",\"enabled\":")
        out.appendBoolean(node.enabled)
        out.appendAscii(",\"visible\":")
        out.appendBoolean(node.visible)
        out.appendByte('}'.code)
    }

    private fun appendNodePatch(patch: ShadowNodePatch, out: ByteArrayBuffer) {
        val node = patch.node
        val mask = patch.mask
        out.appendAscii("{\"node_id\":")
        out.appendLong(node.nodeId)
        out.appendAscii(",\"mask\":")
        out.appendInt(mask)
        if ((mask and ShadowNode.PATCH_PARENT) != 0) {
            out.appendAscii(",\"parent_id\":")
            if (node.parentId == null) out.appendAscii("null") else out.appendLong(node.parentId)
        }
        if ((mask and ShadowNode.PATCH_ORDER) != 0) {
            out.appendAscii(",\"index\":")
            out.appendInt(node.index)
            out.appendAscii(",\"child_index\":")
            out.appendInt(node.childIndex)
            out.appendAscii(",\"depth\":")
            out.appendInt(node.depth)
        }
        if ((mask and ShadowNode.PATCH_TEXT) != 0) {
            out.appendAscii(",\"text\":")
            out.appendJsonString(node.text)
        }
        if ((mask and ShadowNode.PATCH_CONTENT_DESC) != 0) {
            out.appendAscii(",\"content_desc\":")
            out.appendJsonString(node.contentDesc)
        }
        if ((mask and ShadowNode.PATCH_RESOURCE_ID) != 0) {
            out.appendAscii(",\"resource_id\":")
            out.appendJsonString(node.resourceId)
        }
        if ((mask and ShadowNode.PATCH_CLASS) != 0) {
            out.appendAscii(",\"class\":")
            out.appendJsonString(node.className)
            out.appendAscii(",\"package_name\":")
            out.appendJsonString(node.packageName)
        }
        if ((mask and ShadowNode.PATCH_BOUNDS) != 0) {
            out.appendAscii(",\"bounds\":")
            appendBoundsString(node, out)
            out.appendAscii(",\"center_x\":")
            out.appendInt(node.centerX)
            out.appendAscii(",\"center_y\":")
            out.appendInt(node.centerY)
        }
        if ((mask and ShadowNode.PATCH_FLAGS) != 0) {
            out.appendAscii(",\"clickable\":")
            out.appendBoolean(node.clickable)
            out.appendAscii(",\"scrollable\":")
            out.appendBoolean(node.scrollable)
            out.appendAscii(",\"editable\":")
            out.appendBoolean(node.editable)
            out.appendAscii(",\"focused\":")
            out.appendBoolean(node.focused)
            out.appendAscii(",\"checked\":")
            out.appendBoolean(node.checked)
            out.appendAscii(",\"enabled\":")
            out.appendBoolean(node.enabled)
            out.appendAscii(",\"visible\":")
            out.appendBoolean(node.visible)
        }
        out.appendByte('}'.code)
    }

    private fun appendBoundsString(node: ShadowNode, out: ByteArrayBuffer) {
        out.appendAscii("\"[")
        out.appendInt(node.left)
        out.appendByte(','.code)
        out.appendInt(node.top)
        out.appendAscii("][")
        out.appendInt(node.right)
        out.appendByte(','.code)
        out.appendInt(node.bottom)
        out.appendAscii("]\"")
    }
}
