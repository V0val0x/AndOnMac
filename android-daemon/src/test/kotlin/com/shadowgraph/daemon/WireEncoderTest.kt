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
import com.shadowgraph.daemon.transport.WireInputResult
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

    @Test
    fun `encodes hello capabilities and input_result frames and parses input commands`() {
        val buf = ByteArrayBuffer(128)

        encoder.encodeHello(WireHello(1, "ndjson/1", 37, "Pixel 10a", 999L, listOf("input")), buf)
        val helloJson = decode(buf)
        assertTrue(helloJson.contains("\"capabilities\":[\"input\"]"))

        encoder.encodeInputResult(
            WireInputResult(id = 7L, cmd = "tap", ok = true, error = null, elapsedMs = 6L, timestampMs = 5555L),
            buf
        )
        assertEquals(
            "{\"type\":\"input_result\",\"id\":7,\"cmd\":\"tap\",\"ok\":true,\"elapsed_ms\":6,\"ts_ms\":5555}\n",
            decode(buf)
        )

        encoder.encodeInputResult(
            WireInputResult(id = 8L, cmd = "swipe", ok = false, error = "uia_null", elapsedMs = 1L, timestampMs = 5556L),
            buf
        )
        assertEquals(
            "{\"type\":\"input_result\",\"id\":8,\"cmd\":\"swipe\",\"ok\":false,\"error\":\"uia_null\",\"elapsed_ms\":1,\"ts_ms\":5556}\n",
            decode(buf)
        )

        val tap = assertIs<InboundCommand.Tap>(CommandParser.parseLine("{\"cmd\":\"tap\",\"id\":11,\"x\":540,\"y\":1200}"))
        assertEquals(11L, tap.id)
        assertEquals(540, tap.x)
        assertEquals(1200, tap.y)

        val tapNoId = assertIs<InboundCommand.Tap>(CommandParser.parseLine("{\"cmd\":\"tap\",\"x\":10,\"y\":20}"))
        assertEquals(0L, tapNoId.id)

        val swipe = assertIs<InboundCommand.Swipe>(
            CommandParser.parseLine("{\"cmd\":\"swipe\",\"id\":12,\"x1\":540,\"y1\":1900,\"x2\":540,\"y2\":400,\"duration_ms\":150,\"hold_ms\":30}")
        )
        assertEquals(12L, swipe.id)
        assertEquals(540, swipe.x1)
        assertEquals(1900, swipe.y1)
        assertEquals(540, swipe.x2)
        assertEquals(400, swipe.y2)
        assertEquals(150L, swipe.durationMs)
        assertEquals(30L, swipe.holdMs)

        val swipeDefaults = assertIs<InboundCommand.Swipe>(
            CommandParser.parseLine("{\"cmd\":\"swipe\",\"x1\":100,\"y1\":800,\"x2\":100,\"y2\":200}")
        )
        assertEquals(145L, swipeDefaults.durationMs)
        assertEquals(25L, swipeDefaults.holdMs)

        val key = assertIs<InboundCommand.Keyevent>(
            CommandParser.parseLine("{\"cmd\":\"keyevent\",\"id\":13,\"keycode\":4}")
        )
        assertEquals(13L, key.id)
        assertEquals(4, key.keycode)

        // Boundary and error validations
        assertIs<InboundCommand.Unknown>(CommandParser.parseLine("{\"cmd\":\"tap\",\"x\":-1,\"y\":10}"))
        assertIs<InboundCommand.Unknown>(CommandParser.parseLine("{\"cmd\":\"tap\",\"x\":99999,\"y\":10}"))
        assertIs<InboundCommand.Unknown>(CommandParser.parseLine("{\"cmd\":\"tap\",\"x\":10}"))
        assertIs<InboundCommand.Unknown>(CommandParser.parseLine("{\"cmd\":\"swipe\",\"x1\":10,\"y1\":20,\"x2\":30,\"y2\":40,\"duration_ms\":5}"))
        assertIs<InboundCommand.Unknown>(CommandParser.parseLine("{\"cmd\":\"swipe\",\"x1\":10,\"y1\":20,\"x2\":30,\"y2\":40,\"hold_ms\":-1}"))
        assertIs<InboundCommand.Unknown>(CommandParser.parseLine("{\"cmd\":\"keyevent\",\"keycode\":0}"))
        assertIs<InboundCommand.Unknown>(CommandParser.parseLine("{\"cmd\":\"keyevent\",\"keycode\":2000}"))
        assertIs<InboundCommand.Unknown>(CommandParser.parseLine("{\"cmd\":\"tap\",\"id\":-5,\"x\":10,\"y\":20}"))

        // Invalid input commands carrying an explicit id preserve (id, cmd) so daemon can reply fail-fast input_result
        val badTapWithId = assertIs<InboundCommand.Unknown>(
            CommandParser.parseLine("{\"cmd\":\"tap\",\"id\":777,\"x\":99999,\"y\":10}")
        )
        assertEquals(777L, badTapWithId.id)
        assertEquals("tap", badTapWithId.cmd)
        assertEquals("missing_or_invalid_x", badTapWithId.reason)

        val badKeyWithId = assertIs<InboundCommand.Unknown>(
            CommandParser.parseLine("{\"cmd\":\"keyevent\",\"id\":778,\"keycode\":0}")
        )
        assertEquals(778L, badKeyWithId.id)
        assertEquals("keyevent", badKeyWithId.cmd)
    }
}
