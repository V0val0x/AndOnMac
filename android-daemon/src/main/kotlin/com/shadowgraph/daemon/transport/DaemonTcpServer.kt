package com.shadowgraph.daemon.transport

import com.shadowgraph.daemon.graph.ShadowTreeSnapshot
import com.shadowgraph.daemon.graph.TreeDiffResult
import java.io.IOException
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.SocketException
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong

/**
 * Loopback-only (`127.0.0.1`) TCP server managing multi-client streaming sessions.
 * Encodes each broadcast frame once via [WireEncoder] and fans out immutable payloads.
 */
class DaemonTcpServer(
    private val port: Int,
    private val queueCapacity: Int,
    val encoder: WireEncoder,
    private val listener: Listener,
    private val deferBroadcastUntilSnapshot: Boolean = false
) {
    interface Listener {
        fun onClientConnected(session: ClientSession)
        fun onCommand(session: ClientSession, command: InboundCommand)
        fun onResyncRequested(session: ClientSession)
        fun onServerError(error: Throwable)
    }

    private val running = AtomicBoolean(false)
    private val nextClientId = AtomicLong(1L)
    private val sessions = CopyOnWriteArrayList<ClientSession>()
    private val encodeLock = Any()
    private val encodeBuffer = ByteArrayBuffer(32 * 1024)

    @Volatile
    private var serverSocket: ServerSocket? = null
    private var acceptThread: Thread? = null

    val boundPort: Int
        get() = serverSocket?.localPort ?: -1

    val clientCount: Int
        get() = sessions.size

    fun start() {
        if (!running.compareAndSet(false, true)) return
        val ss = ServerSocket()
        ss.reuseAddress = true
        ss.bind(InetSocketAddress(InetAddress.getByName("127.0.0.1"), port), 16)
        serverSocket = ss

        acceptThread = Thread({ acceptLoop(ss) }, "shadow-tcp-accept").apply {
            isDaemon = true
            start()
        }
    }

    private fun acceptLoop(ss: ServerSocket) {
        while (running.get() && !ss.isClosed) {
            try {
                val socket = ss.accept()
                val session = ClientSession(
                    id = nextClientId.getAndIncrement(),
                    socket = socket,
                    queueCapacity = queueCapacity,
                    initialBroadcastReady = !deferBroadcastUntilSnapshot,
                    onCommand = { s, cmd -> listener.onCommand(s, cmd) },
                    onResyncRequested = { s -> listener.onResyncRequested(s) },
                    onClosed = { s -> sessions.remove(s) }
                )
                sessions.add(session)
                session.start()
                listener.onClientConnected(session)
            } catch (e: SocketException) {
                if (running.get()) {
                    listener.onServerError(e)
                }
                break
            } catch (e: IOException) {
                if (running.get()) {
                    listener.onServerError(e)
                }
            }
        }
    }

    fun sendHello(session: ClientSession, hello: WireHello) {
        val bytes = encode { encoder.encodeHello(hello, it) }
        session.enqueue(OutboundFrame(bytes, isDiff = false))
    }

    fun sendSnapshot(session: ClientSession, snapshot: ShadowTreeSnapshot, reason: String) {
        val bytes = encode { encoder.encodeSnapshot(WireSnapshot(snapshot, reason), it) }
        session.enqueue(OutboundFrame(bytes, isDiff = false, isSnapshot = true))
    }

    fun sendPong(session: ClientSession, pong: WirePong) {
        val bytes = encode { encoder.encodePong(pong, it) }
        session.enqueue(OutboundFrame(bytes, isDiff = false))
    }

    fun sendError(session: ClientSession, error: WireError) {
        val bytes = encode { encoder.encodeError(error, it) }
        session.enqueue(OutboundFrame(bytes, isDiff = false))
    }

    fun broadcastSnapshot(
        snapshot: ShadowTreeSnapshot,
        reason: String,
        excludeSession: ClientSession? = null
    ) {
        if (sessions.isEmpty()) return
        val bytes = encode { encoder.encodeSnapshot(WireSnapshot(snapshot, reason), it) }
        val frame = OutboundFrame(bytes, isDiff = false, isSnapshot = true)
        for (session in sessions) {
            if (session !== excludeSession) {
                session.enqueue(frame, isBroadcast = true)
            }
        }
    }

    fun broadcastDiff(
        diff: TreeDiffResult.IncrementalDiff,
        eventType: Int? = null,
        eventPackage: String? = null,
        excludeSession: ClientSession? = null
    ) {
        if (sessions.isEmpty()) return
        val bytes = encode { encoder.encodeDiff(WireDiff(diff, eventType, eventPackage), it) }
        val frame = OutboundFrame(bytes, isDiff = true)
        for (session in sessions) {
            if (session !== excludeSession) {
                session.enqueue(frame, isBroadcast = true)
            }
        }
    }

    fun broadcastHeartbeat(
        seq: Long,
        timestampMs: Long,
        uptimeMs: Long,
        activePackage: String,
        activeWindowId: Int
    ) {
        if (sessions.isEmpty()) return
        val hb = WireHeartbeat(
            seq = seq,
            timestampMs = timestampMs,
            uptimeMs = uptimeMs,
            activePackage = activePackage,
            activeWindowId = activeWindowId,
            clientCount = sessions.size
        )
        val bytes = encode { encoder.encodeHeartbeat(hb, it) }
        val frame = OutboundFrame(bytes, isDiff = false)
        for (session in sessions) {
            session.enqueue(frame, isBroadcast = true)
        }
    }

    private inline fun encode(block: (ByteArrayBuffer) -> Unit): ByteArray {
        synchronized(encodeLock) {
            block(encodeBuffer)
            return encodeBuffer.toByteArray()
        }
    }

    fun close() {
        if (!running.compareAndSet(true, false)) return
        try {
            serverSocket?.close()
        } catch (_: IOException) {
        }
        serverSocket = null
        for (session in sessions) {
            session.close()
        }
        sessions.clear()
        acceptThread?.interrupt()
    }
}
