package com.shadowgraph.daemon.transport

import java.io.BufferedReader
import java.io.IOException
import java.io.InputStreamReader
import java.io.OutputStream
import java.net.Socket
import java.nio.charset.StandardCharsets
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.atomic.AtomicBoolean

class OutboundFrame(
    val payload: ByteArray,
    val isDiff: Boolean,
    val isSnapshot: Boolean = false,
    val isHeartbeat: Boolean = false
)

/**
 * Per-client TCP session with bounded drop-oldest queue, resync flag on overflow,
 * dedicated writer thread, and inbound NDJSON command reader thread.
 */
class ClientSession(
    val id: Long,
    private val socket: Socket,
    queueCapacity: Int,
    initialBroadcastReady: Boolean = true,
    private val onCommand: (ClientSession, InboundCommand) -> Unit,
    private val onResyncRequested: (ClientSession) -> Unit,
    private val onClosed: (ClientSession) -> Unit
) {
    private val queue = ArrayBlockingQueue<OutboundFrame>(queueCapacity)
    private val closed = AtomicBoolean(false)
    private val needsResync = AtomicBoolean(false)
    @Volatile
    private var broadcastReady: Boolean = initialBroadcastReady
    private val enqueueLock = Any()
    private var pendingSnapshot: OutboundFrame? = null

    val isClosed: Boolean
        get() = closed.get()

    private var writerThread: Thread? = null
    private var readerThread: Thread? = null

    fun start() {
        socket.tcpNoDelay = true
        val out = socket.getOutputStream()
        val reader = BufferedReader(InputStreamReader(socket.getInputStream(), StandardCharsets.UTF_8))

        writerThread = Thread({ writerLoop(out) }, "shadow-client-writer-$id").apply {
            isDaemon = true
            start()
        }
        readerThread = Thread({ readerLoop(reader) }, "shadow-client-reader-$id").apply {
            isDaemon = true
            start()
        }
    }

    fun enqueue(frame: OutboundFrame, isBroadcast: Boolean = false) {
        if (closed.get()) return
        var triggerResync = false
        synchronized(enqueueLock) {
            if (closed.get()) return
            if (isBroadcast && !broadcastReady) {
                // Hold off broadcasts (diffs/heartbeats/external snapshots) until initial snapshot is sent
                return
            }
            if (frame.isSnapshot) {
                // Snapshot supersedes any stale queued diffs/snapshots/heartbeats and marks stream ready for diffs.
                queue.removeIf { it.isDiff || it.isSnapshot || it.isHeartbeat }
                pendingSnapshot = null
                if (queue.offer(frame)) {
                    needsResync.set(false)
                    broadcastReady = true
                } else {
                    // Queue is 100% saturated with high-priority control frames (e.g. input_result).
                    // Stash latest snapshot so writerLoop promotes it immediately when a slot frees,
                    // avoiding permanent needsResync deadlock without dropping control frames.
                    pendingSnapshot = frame
                    needsResync.set(true)
                }
                return
            }
            if (frame.isHeartbeat) {
                // Heartbeats are low-priority liveness probes: drop on congestion rather than
                // evicting control/ACK frames or triggering resync.
                queue.offer(frame)
                return
            }
            if (frame.isDiff && (needsResync.get() || pendingSnapshot != null)) {
                // Drop incremental diffs until resync snapshot is delivered
                return
            }
            if (!queue.offer(frame)) {
                if (frame.isDiff) {
                    // Don't enqueue orphaned diff after overflow; drop only stale state/heartbeat frames
                    // so control/ACK frames (input_result, hello, pong, secure_screen, error) are never lost.
                    queue.removeIf { it.isDiff || it.isSnapshot || it.isHeartbeat }
                    if (needsResync.compareAndSet(false, true)) {
                        triggerResync = true
                    }
                } else {
                    // Prefer evicting oldest heartbeat, then oldest diff/snapshot, so control/ACK frames survive bursts.
                    val victim = queue.firstOrNull { it.isHeartbeat }
                        ?: queue.firstOrNull { it.isDiff || it.isSnapshot }
                    val evicted = if (victim != null && queue.remove(victim)) {
                        victim
                    } else {
                        queue.poll()
                    }
                    if (evicted != null && (evicted.isDiff || evicted.isSnapshot)) {
                        if (needsResync.compareAndSet(false, true)) {
                            triggerResync = true
                        }
                    }
                    queue.offer(frame)
                }
            }
        }
        if (triggerResync) {
            onResyncRequested(this)
        }
    }

    private fun promotePendingSnapshotLocked() {
        val pending = pendingSnapshot ?: return
        if (closed.get()) {
            pendingSnapshot = null
            return
        }
        queue.removeIf { it.isDiff || it.isSnapshot || it.isHeartbeat }
        if (queue.offer(pending)) {
            pendingSnapshot = null
            needsResync.set(false)
            broadcastReady = true
        }
    }

    private fun writerLoop(out: OutputStream) {
        try {
            while (!closed.get()) {
                val frame = queue.take()
                if (frame === POISON_FRAME || closed.get()) break
                synchronized(enqueueLock) {
                    promotePendingSnapshotLocked()
                }
                out.write(frame.payload)
                // Coalesce flush if more frames are already queued
                if (queue.isEmpty()) {
                    out.flush()
                }
            }
        } catch (_: InterruptedException) {
            // Shutdown
        } catch (_: IOException) {
            // Client disconnected
        } finally {
            close()
        }
    }

    private fun readerLoop(reader: BufferedReader) {
        try {
            while (!closed.get()) {
                val line = reader.readLine() ?: break
                if (line.isBlank()) continue
                val cmd = CommandParser.parseLine(line)
                onCommand(this, cmd)
            }
        } catch (_: IOException) {
            // Socket closed / reset
        } finally {
            close()
        }
    }

    fun close() {
        if (!closed.compareAndSet(false, true)) return
        synchronized(enqueueLock) {
            pendingSnapshot = null
            queue.clear()
            queue.offer(POISON_FRAME)
        }
        try {
            socket.close()
        } catch (_: IOException) {
        }
        writerThread?.interrupt()
        onClosed(this)
    }

    companion object {
        private val POISON_FRAME = OutboundFrame(ByteArray(0), isDiff = false)
    }
}
