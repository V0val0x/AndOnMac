package com.shadowgraph.daemon

import com.shadowgraph.daemon.graph.ShadowNode
import com.shadowgraph.daemon.graph.ShadowTreeSnapshot
import com.shadowgraph.daemon.graph.TreeDiffResult
import com.shadowgraph.daemon.transport.ClientSession
import com.shadowgraph.daemon.transport.DaemonTcpServer
import com.shadowgraph.daemon.transport.InboundCommand
import com.shadowgraph.daemon.transport.NdjsonWireEncoder
import com.shadowgraph.daemon.transport.WireHello
import com.shadowgraph.daemon.transport.WireInputResult
import com.shadowgraph.daemon.transport.WirePong
import java.io.BufferedReader
import java.io.BufferedWriter
import java.io.InputStreamReader
import java.io.OutputStreamWriter
import java.net.InetAddress
import java.net.Socket
import java.nio.charset.StandardCharsets
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertTrue

class DaemonTcpServerTest {
    private fun sampleSnapshot(seq: Long, text: String = "Settings"): ShadowTreeSnapshot {
        val node = ShadowNode(
            nodeId = 100L,
            parentId = null,
            windowId = 1,
            index = 0,
            childIndex = 0,
            depth = 0,
            packageName = "com.android.settings",
            className = "TextView",
            resourceId = "android:id/title",
            text = text,
            contentDesc = "",
            left = 0,
            top = 0,
            right = 400,
            bottom = 100,
            clickable = true,
            scrollable = false,
            editable = false,
            focused = false,
            checked = false,
            enabled = true,
            visible = true
        )
        return ShadowTreeSnapshot.fromNodes(
            seq = seq,
            timestampNs = seq * 1000L,
            timestampMs = 1700000000000L + seq,
            activePackage = "com.android.settings",
            activeWindowId = 1,
            nodes = listOf(node)
        )
    }

    @Test
    fun `binds to loopback, sends hello and snapshot, handles ping, and fans out diffs`() {
        val snap = sampleSnapshot(seq = 1L)
        val resyncCount = AtomicInteger(0)
        val connectedLatch = CountDownLatch(2)

        lateinit var server: DaemonTcpServer
        server = DaemonTcpServer(
            port = 0,
            queueCapacity = 16,
            encoder = NdjsonWireEncoder(),
            listener = object : DaemonTcpServer.Listener {
                override fun onClientConnected(session: ClientSession) {
                    server.sendHello(session, WireHello(1, "ndjson/1", 37, "TestModel", 1234L))
                    server.sendSnapshot(session, snap, "initial")
                    connectedLatch.countDown()
                }

                override fun onCommand(session: ClientSession, command: InboundCommand) {
                    when (command) {
                        is InboundCommand.Ping -> server.sendPong(session, WirePong(123456L, 1L))
                        is InboundCommand.Tap -> server.sendInputResult(
                            session,
                            WireInputResult(command.id, "tap", ok = true, elapsedMs = 4L, timestampMs = 123457L)
                        )
                        is InboundCommand.Swipe -> server.sendInputResult(
                            session,
                            WireInputResult(command.id, "swipe", ok = true, elapsedMs = 170L, timestampMs = 123458L)
                        )
                        is InboundCommand.Keyevent -> server.sendInputResult(
                            session,
                            WireInputResult(command.id, "keyevent", ok = true, elapsedMs = 3L, timestampMs = 123459L)
                        )
                        else -> {}
                    }
                }

                override fun onResyncRequested(session: ClientSession) {
                    resyncCount.incrementAndGet()
                }

                override fun onServerError(error: Throwable) {
                }
            }
        )

        server.start()
        try {
            val port = server.boundPort
            assertTrue(port > 0)
            assertEquals("127.0.0.1", server.boundHost)

            val c1 = Socket(InetAddress.getByName("127.0.0.1"), port)
            val c2 = Socket(InetAddress.getByName("127.0.0.1"), port)
            c1.soTimeout = 3000
            c2.soTimeout = 3000

            try {
                assertTrue(connectedLatch.await(3, TimeUnit.SECONDS))

                val r1 = BufferedReader(InputStreamReader(c1.getInputStream(), StandardCharsets.UTF_8))
                val r2 = BufferedReader(InputStreamReader(c2.getInputStream(), StandardCharsets.UTF_8))
                val w1 = BufferedWriter(OutputStreamWriter(c1.getOutputStream(), StandardCharsets.UTF_8))

                val hello1 = r1.readLine()
                val snap1 = r1.readLine()
                val hello2 = r2.readLine()
                val snap2 = r2.readLine()

                assertNotNull(hello1)
                assertNotNull(snap1)
                assertTrue(hello1.contains("\"type\":\"hello\""))
                assertTrue(snap1.contains("\"type\":\"snapshot\""))
                assertTrue(hello2.contains("\"type\":\"hello\""))
                assertTrue(snap2.contains("\"type\":\"snapshot\""))

                // Broadcast an incremental diff to both clients
                val diff = TreeDiffResult.IncrementalDiff(
                    baseSeq = 1L,
                    seq = 2L,
                    timestampMs = 1700000000002L,
                    activePackage = "com.android.settings",
                    activeWindowId = 1,
                    inserted = emptyList(),
                    updated = emptyList(),
                    removedIds = listOf(100L)
                )
                server.broadcastDiff(diff)

                val diffLine1 = r1.readLine()
                val diffLine2 = r2.readLine()
                assertTrue(diffLine1.contains("\"type\":\"diff\""))
                assertTrue(diffLine1.contains("\"removed\":[100]"))
                assertTrue(diffLine2.contains("\"type\":\"diff\""))

                // Send ping from c1 -> expect pong
                w1.write("{\"cmd\":\"ping\"}\n")
                w1.flush()
                val pongLine = r1.readLine()
                assertEquals("{\"type\":\"pong\",\"ts_ms\":123456,\"seq\":1}", pongLine)

                // Send tap, swipe, keyevent -> expect structured input_result acks
                w1.write("{\"cmd\":\"tap\",\"id\":101,\"x\":540,\"y\":1200}\n")
                w1.write("{\"cmd\":\"swipe\",\"id\":102,\"x1\":540,\"y1\":1900,\"x2\":540,\"y2\":450,\"duration_ms\":145,\"hold_ms\":25}\n")
                w1.write("{\"cmd\":\"keyevent\",\"id\":103,\"keycode\":4}\n")
                w1.flush()
                assertEquals(
                    "{\"type\":\"input_result\",\"id\":101,\"cmd\":\"tap\",\"ok\":true,\"elapsed_ms\":4,\"ts_ms\":123457}",
                    r1.readLine()
                )
                assertEquals(
                    "{\"type\":\"input_result\",\"id\":102,\"cmd\":\"swipe\",\"ok\":true,\"elapsed_ms\":170,\"ts_ms\":123458}",
                    r1.readLine()
                )
                assertEquals(
                    "{\"type\":\"input_result\",\"id\":103,\"cmd\":\"keyevent\",\"ok\":true,\"elapsed_ms\":3,\"ts_ms\":123459}",
                    r1.readLine()
                )
            } finally {
                c1.close()
                c2.close()
            }
        } finally {
            server.close()
        }
    }

    @Test
    fun `drops stale diffs and triggers resync when client outbound queue overflows`() {
        val snap = sampleSnapshot(seq = 1L)
        val resyncLatch = CountDownLatch(1)
        val connectedLatch = CountDownLatch(1)
        val sessionRef = java.util.concurrent.atomic.AtomicReference<ClientSession?>()

        lateinit var server: DaemonTcpServer
        server = DaemonTcpServer(
            port = 0,
            queueCapacity = 4,
            encoder = NdjsonWireEncoder(),
            listener = object : DaemonTcpServer.Listener {
                override fun onClientConnected(session: ClientSession) {
                    sessionRef.set(session)
                    connectedLatch.countDown()
                }

                override fun onCommand(session: ClientSession, command: InboundCommand) {}

                override fun onResyncRequested(session: ClientSession) {
                    resyncLatch.countDown()
                    server.sendSnapshot(session, snap, "resync")
                }

                override fun onServerError(error: Throwable) {}
            }
        )

        server.start()
        try {
            val client = Socket(InetAddress.getByName("127.0.0.1"), server.boundPort)
            client.receiveBufferSize = 1024
            try {
                assertTrue(connectedLatch.await(3, TimeUnit.SECONDS))
                // Flood large diffs faster than socket/reader drains to force queue overflow
                val largeNodes = (1..200).map { i ->
                    ShadowNode(
                        nodeId = i.toLong(),
                        parentId = null,
                        windowId = 1,
                        index = i,
                        childIndex = i,
                        depth = 1,
                        packageName = "com.example",
                        className = "TextView",
                        resourceId = "id/$i",
                        text = "Item $i ".repeat(20),
                        contentDesc = "",
                        left = 0,
                        top = i * 10,
                        right = 500,
                        bottom = i * 10 + 50,
                        clickable = true,
                        scrollable = false,
                        editable = false,
                        focused = false,
                        checked = false,
                        enabled = true,
                        visible = true
                    )
                }
                for (seq in 2L..80L) {
                    val diff = TreeDiffResult.IncrementalDiff(
                        baseSeq = seq - 1,
                        seq = seq,
                        timestampMs = 1700000000000L + seq,
                        activePackage = "com.example",
                        activeWindowId = 1,
                        inserted = largeNodes,
                        updated = emptyList(),
                        removedIds = emptyList()
                    )
                    server.broadcastDiff(diff)
                    if (resyncLatch.count == 0L) break
                }
                assertTrue(resyncLatch.await(3, TimeUnit.SECONDS), "Expected onResyncRequested on slow client overflow")
            } finally {
                client.close()
            }
        } finally {
            server.close()
        }
    }

    @Test
    fun `defers broadcasts until initial snapshot when deferBroadcastUntilSnapshot is enabled`() {
        val snap = sampleSnapshot(seq = 2L)
        val connectedLatch = CountDownLatch(1)
        val sessionRef = java.util.concurrent.atomic.AtomicReference<ClientSession?>()

        lateinit var server: DaemonTcpServer
        server = DaemonTcpServer(
            port = 0,
            queueCapacity = 16,
            encoder = NdjsonWireEncoder(),
            deferBroadcastUntilSnapshot = true,
            listener = object : DaemonTcpServer.Listener {
                override fun onClientConnected(session: ClientSession) {
                    server.sendHello(session, WireHello(1, "ndjson/1", 37, "TestModel", 1234L))
                    sessionRef.set(session)
                    connectedLatch.countDown()
                }

                override fun onCommand(session: ClientSession, command: InboundCommand) {}
                override fun onResyncRequested(session: ClientSession) {}
                override fun onServerError(error: Throwable) {}
            }
        )

        server.start()
        try {
            val client = Socket(InetAddress.getByName("127.0.0.1"), server.boundPort)
            client.soTimeout = 3000
            try {
                assertTrue(connectedLatch.await(3, TimeUnit.SECONDS))
                val session = sessionRef.get()!!

                // Broadcast before initial snapshot is sent -> must be suppressed for this session
                val earlyDiff = TreeDiffResult.IncrementalDiff(
                    baseSeq = 1L,
                    seq = 2L,
                    timestampMs = 1700000000002L,
                    activePackage = "com.android.settings",
                    activeWindowId = 1,
                    inserted = emptyList(),
                    updated = emptyList(),
                    removedIds = listOf(100L)
                )
                server.broadcastDiff(earlyDiff)
                server.broadcastHeartbeat(2L, 1700000000002L, 100L, "com.android.settings", 1)

                // Now deliver initial snapshot, then broadcast seq 2->3 excluding nobody
                server.sendSnapshot(session, snap, "initial")
                val nextDiff = earlyDiff.copy(baseSeq = 2L, seq = 3L)
                server.broadcastDiff(nextDiff)

                val reader = BufferedReader(InputStreamReader(client.getInputStream(), StandardCharsets.UTF_8))
                val l1 = reader.readLine()
                val l2 = reader.readLine()
                val l3 = reader.readLine()

                assertTrue(l1.contains("\"type\":\"hello\""))
                assertTrue(l2.contains("\"type\":\"snapshot\""))
                assertTrue(l3.contains("\"type\":\"diff\"") && l3.contains("\"base_seq\":2"))
            } finally {
                client.close()
            }
        } finally {
            server.close()
        }
    }

    @Test
    fun `preserves queued input_result control frames across diff queue overflow`() {
        val snap = sampleSnapshot(seq = 1L)
        val connectedLatch = CountDownLatch(1)
        val resyncLatch = CountDownLatch(1)
        val sessionRef = java.util.concurrent.atomic.AtomicReference<ClientSession?>()

        lateinit var server: DaemonTcpServer
        server = DaemonTcpServer(
            port = 0,
            queueCapacity = 3,
            encoder = NdjsonWireEncoder(),
            listener = object : DaemonTcpServer.Listener {
                override fun onClientConnected(session: ClientSession) {
                    sessionRef.set(session)
                    connectedLatch.countDown()
                }

                override fun onCommand(session: ClientSession, command: InboundCommand) {}

                override fun onResyncRequested(session: ClientSession) {
                    resyncLatch.countDown()
                    server.sendSnapshot(session, snap, "resync")
                }

                override fun onServerError(error: Throwable) {}
            }
        )

        server.start()
        try {
            val client = Socket(InetAddress.getByName("127.0.0.1"), server.boundPort)
            client.receiveBufferSize = 1024
            client.soTimeout = 3000
            try {
                assertTrue(connectedLatch.await(3, TimeUnit.SECONDS))
                val session = sessionRef.get()!!

                val largeNodes = (1..200).map { i ->
                    ShadowNode(
                        nodeId = i.toLong(),
                        parentId = null,
                        windowId = 1,
                        index = i,
                        childIndex = i,
                        depth = 1,
                        packageName = "com.example",
                        className = "TextView",
                        resourceId = "id/$i",
                        text = "Item $i ".repeat(20),
                        contentDesc = "",
                        left = 0,
                        top = i * 10,
                        right = 500,
                        bottom = i * 10 + 50,
                        clickable = true,
                        scrollable = false,
                        editable = false,
                        focused = false,
                        checked = false,
                        enabled = true,
                        visible = true
                    )
                }

                // Enqueue a burst of diffs + a critical input_result ACK + more diffs to trigger overflow
                for (seq in 2L..25L) {
                    if (seq == 12L) {
                        server.sendInputResult(
                            session,
                            WireInputResult(
                                id = 4242L,
                                cmd = "tap",
                                ok = true,
                                elapsedMs = 5L,
                                timestampMs = 1700000000100L
                            )
                        )
                    }
                    val diff = TreeDiffResult.IncrementalDiff(
                        baseSeq = seq - 1,
                        seq = seq,
                        timestampMs = 1700000000000L + seq,
                        activePackage = "com.example",
                        activeWindowId = 1,
                        inserted = largeNodes,
                        updated = emptyList(),
                        removedIds = emptyList()
                    )
                    server.broadcastDiff(diff)
                }

                assertTrue(resyncLatch.await(3, TimeUnit.SECONDS), "Expected overflow resync to trigger")

                // Drain client frames and verify input_result id=4242 was NEVER dropped by overflow
                val reader = BufferedReader(InputStreamReader(client.getInputStream(), StandardCharsets.UTF_8))
                var sawInputResult = false
                var sawResyncSnap = false
                val deadline = System.currentTimeMillis() + 2500L
                while (System.currentTimeMillis() < deadline && (!sawInputResult || !sawResyncSnap)) {
                    val line = reader.readLine() ?: break
                    if (line.contains("\"type\":\"input_result\"") && line.contains("\"id\":4242")) {
                        sawInputResult = true
                    }
                    if (line.contains("\"type\":\"snapshot\"") && line.contains("\"reason\":\"resync\"")) {
                        sawResyncSnap = true
                    }
                }
                assertTrue(sawInputResult, "Expected queued input_result id=4242 to survive diff queue overflow")
                assertTrue(sawResyncSnap, "Expected resync snapshot after diff overflow")
            } finally {
                client.close()
            }
        } finally {
            server.close()
        }
    }
}
