package com.shadowgraph.daemon

import com.shadowgraph.daemon.graph.ShadowNode
import com.shadowgraph.daemon.graph.ShadowNodePatch
import com.shadowgraph.daemon.graph.ShadowTreeSnapshot
import com.shadowgraph.daemon.graph.TreeDiffResult
import com.shadowgraph.daemon.transport.ByteArrayBuffer
import com.shadowgraph.daemon.transport.CommandParser
import com.shadowgraph.daemon.transport.InboundCommand
import com.shadowgraph.daemon.transport.NdjsonWireEncoder
import com.shadowgraph.daemon.transport.WireDiff
import com.shadowgraph.daemon.transport.WireError
import com.shadowgraph.daemon.transport.WireHello
import com.shadowgraph.daemon.transport.WirePong
import com.shadowgraph.daemon.transport.WireSecureScreen
import com.shadowgraph.daemon.transport.WireSnapshot
import java.nio.charset.StandardCharsets
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertIs
import kotlin.test.assertTrue

class WireEncoderTest {
    private val encoder = NdjsonWireEncoder()

    private fun decode(buf: ByteArrayBuffer): String =
        String(buf.data, 0, buf.size, StandardCharsets.UTF_8)

    @Test
    fun `encodes snapshot with AndroidUINode compatible keys and UTF-8 escaping`() {
        val node = ShadowNode(
            nodeId = 42L,
            parentId = null,
            windowId = 7,
            index = 0,
            childIndex = 0,
            depth = 0,
            packageName = "com.example.app",
            className = "TextView",
            resourceId = "com.example.app:id/label",
            text = "Привет \"мир\"\nLine2\\slash\t\u0007🚀",
            contentDesc = "Desc",
            left = 10,
            top = 20,
            right = 110,
            bottom = 80,
            clickable = true,
            scrollable = false,
            editable = false,
            focused = true,
            checked = false,
            enabled = true,
            visible = true
        )
        val snap = ShadowTreeSnapshot.fromNodes(
            seq = 1L,
            timestampNs = 1000L,
            timestampMs = 1700000000000L,
            activePackage = "com.example.app",
            activeWindowId = 7,
            nodes = listOf(node)
        )

        val buf = ByteArrayBuffer(256)
        encoder.encodeSnapshot(WireSnapshot(snap, "initial"), buf)
        val json = decode(buf)

        assertTrue(json.endsWith("\n"))
        assertEquals(1, json.count { it == '\n' })
        assertTrue(json.contains("\"type\":\"snapshot\""))
        assertTrue(json.contains("\"index\":0"))
        assertTrue(json.contains("\"resource_id\":\"com.example.app:id/label\""))
        assertTrue(json.contains("\"content_desc\":\"Desc\""))
        assertTrue(json.contains("\"class\":\"TextView\""))
        assertTrue(json.contains("\"clickable\":true"))
        assertTrue(json.contains("\"scrollable\":false"))
        assertTrue(json.contains("\"bounds\":\"[10,20][110,80]\""))
        assertTrue(json.contains("\"center_x\":60"))
        assertTrue(json.contains("\"center_y\":50"))
        assertTrue(json.contains("\"text\":\"Привет \\\"мир\\\"\\nLine2\\\\slash\\t\\u0007🚀\""))
        assertTrue(json.contains("\"node_id\":42"))
        assertTrue(json.contains("\"parent_id\":null"))
    }

    @Test
    fun `encodes hello, diff, heartbeat, pong, error, and extreme longs`() {
        val buf = ByteArrayBuffer(128)

        encoder.encodeHello(WireHello(1, "ndjson/1", 37, "Pixel 10a", 999L), buf)
        val hello = decode(buf)
        assertTrue(hello.contains("\"type\":\"hello\""))
        assertTrue(hello.contains("\"sdk_int\":37"))
        assertTrue(hello.contains("\"device_model\":\"Pixel 10a\""))

        val updatedNode = ShadowNode(
            nodeId = Long.MIN_VALUE,
            parentId = 10L,
            windowId = 1,
            index = 1,
            childIndex = 0,
            depth = 1,
            packageName = "pkg",
            className = "EditText",
            resourceId = "",
            text = "abc",
            contentDesc = "",
            left = 0,
            top = 0,
            right = 100,
            bottom = 40,
            clickable = true,
            scrollable = false,
            editable = true,
            focused = true,
            checked = false,
            enabled = true,
            visible = true
        )
        val diff = TreeDiffResult.IncrementalDiff(
            baseSeq = 1L,
            seq = 2L,
            timestampMs = 12345L,
            activePackage = "pkg",
            activeWindowId = 1,
            inserted = emptyList(),
            updated = listOf(ShadowNodePatch(updatedNode, ShadowNode.PATCH_TEXT)),
            removedIds = listOf(-55L, 0L)
        )
        encoder.encodeDiff(WireDiff(diff, eventType = 16, eventPackage = "pkg"), buf)
        val diffJson = decode(buf)
        assertTrue(diffJson.contains("\"node_id\":-9223372036854775808"))
        assertTrue(diffJson.contains("\"text\":\"abc\""))
        assertTrue(diffJson.contains("\"removed\":[-55,0]"))
        assertTrue(!diffJson.contains("\"bounds\":"))

        encoder.encodePong(WirePong(timestampMs = 500L, seq = 9L), buf)
        assertEquals("{\"type\":\"pong\",\"ts_ms\":500,\"seq\":9}\n", decode(buf))

        encoder.encodeError(WireError("bad_cmd", "oops", 777L), buf)
        assertEquals("{\"type\":\"error\",\"code\":\"bad_cmd\",\"message\":\"oops\",\"ts_ms\":777}\n", decode(buf))
    }

    @Test
    fun `parses valid and invalid inbound commands`() {
        assertIs<InboundCommand.Snapshot>(CommandParser.parseLine("{\"cmd\":\"snapshot\"}"))
        assertIs<InboundCommand.Ping>(CommandParser.parseLine("  { \"cmd\" : \"ping\" } "))
        assertIs<InboundCommand.Shutdown>(CommandParser.parseLine("{\"cmd\":\"shutdown\"}"))

        val debounce = assertIs<InboundCommand.SetDebounce>(
            CommandParser.parseLine("{\"cmd\":\"set_debounce\",\"ms\":45}")
        )
        assertEquals(45L, debounce.debounceMs)

        assertIs<InboundCommand.Unknown>(CommandParser.parseLine("{\"cmd\":\"set_debounce\",\"ms\":99999}"))
        assertIs<InboundCommand.Unknown>(CommandParser.parseLine("{\"cmd\":\"set_debounce\",\"ms\":-1}"))
        assertEquals(0L, assertIs<InboundCommand.SetDebounce>(CommandParser.parseLine("{\"cmd\":\"set_debounce\",\"ms\":0}")).debounceMs)
        assertEquals(5000L, assertIs<InboundCommand.SetDebounce>(CommandParser.parseLine("{\"cmd\":\"set_debounce\",\"ms\":5000}")).debounceMs)
        assertIs<InboundCommand.Unknown>(CommandParser.parseLine("{\"cmd\":\"ping\",}"))
        assertIs<InboundCommand.Unknown>(CommandParser.parseLine("not json"))
        assertIs<InboundCommand.Unknown>(CommandParser.parseLine("{\"cmd\":\"unknown\"}"))
    }

    @Test
    fun `handles unpaired UTF-16 surrogates without throwing or corrupting NDJSON`() {
        val buf = ByteArrayBuffer(64)
        val badString = "hi\uD800world"
        encoder.encodeError(WireError("surrogate", badString, 1L), buf)
        val decoded = decode(buf)
        assertTrue(decoded.endsWith("\n"))
        assertTrue(decoded.contains("hi\uFFFDworld"))
    }

    @Test
    fun `encodes secure_screen active and cleared frames and snapshot flag`() {
        val buf = ByteArrayBuffer(128)
        encoder.encodeSecureScreen(
            WireSecureScreen(
                code = "SECURE_SCREEN_ACTIVE",
                active = true,
                reason = "flag_secure_null_root",
                activePackage = "com.bank.app",
                timestampMs = 4200L
            ),
            buf
        )
        val activeJson = decode(buf)
        assertTrue(activeJson.startsWith("{\"type\":\"secure_screen\""))
        assertTrue(activeJson.contains("\"code\":\"SECURE_SCREEN_ACTIVE\""))
        assertTrue(activeJson.contains("\"active\":true"))
        assertTrue(activeJson.contains("\"reason\":\"flag_secure_null_root\""))
        assertTrue(activeJson.contains("\"package\":\"com.bank.app\""))

        encoder.encodeSecureScreen(
            WireSecureScreen(
                code = "SECURE_SCREEN_CLEARED",
                active = false,
                reason = "tree_restored",
                activePackage = "com.bank.app",
                timestampMs = 5200L
            ),
            buf
        )
        val clearedJson = decode(buf)
        assertTrue(clearedJson.contains("\"code\":\"SECURE_SCREEN_CLEARED\""))
        assertTrue(clearedJson.contains("\"active\":false"))

        val secureSnap = ShadowTreeSnapshot.fromNodes(
            seq = 9L,
            timestampNs = 900L,
            timestampMs = 4200L,
            activePackage = "com.bank.app",
            activeWindowId = 3,
            nodes = emptyList(),
            secureScreenActive = true,
            secureScreenReason = "empty_accessibility_tree"
        )
        encoder.encodeSnapshot(WireSnapshot(secureSnap, "window_event"), buf)
        val snapJson = decode(buf)
        assertTrue(snapJson.contains("\"secure_screen\":true"))
    }
}
