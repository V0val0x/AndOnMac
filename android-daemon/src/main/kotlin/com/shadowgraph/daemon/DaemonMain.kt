package com.shadowgraph.daemon

import android.os.Build
import android.os.Looper
import android.os.Process
import com.shadowgraph.daemon.accessibility.AccessibilityEventListener
import com.shadowgraph.daemon.accessibility.UiAutomationHost
import com.shadowgraph.daemon.compat.HiddenApiCompat
import com.shadowgraph.daemon.config.DaemonConfig
import com.shadowgraph.daemon.graph.ShadowTreeCollector
import com.shadowgraph.daemon.graph.ShadowTreeDiffer
import com.shadowgraph.daemon.graph.ShadowTreeSnapshot
import com.shadowgraph.daemon.graph.TreeDiffResult
import com.shadowgraph.daemon.transport.ClientSession
import com.shadowgraph.daemon.transport.DaemonTcpServer
import com.shadowgraph.daemon.transport.InboundCommand
import com.shadowgraph.daemon.transport.NdjsonWireEncoder
import com.shadowgraph.daemon.transport.WireError
import com.shadowgraph.daemon.transport.WireHello
import com.shadowgraph.daemon.transport.WirePong
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.RejectedExecutionException
import java.util.concurrent.ScheduledExecutorService
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong
import java.util.concurrent.atomic.AtomicReference

/**
 * Entrypoint for `app_process / com.shadowgraph.daemon.DaemonMain`.
 */
object DaemonMain {
    @JvmStatic
    fun main(args: Array<String>) {
        val config = try {
            DaemonConfig.parse(args)
        } catch (_: DaemonConfig.HelpRequestedException) {
            System.out.print(DaemonConfig.usage())
            return
        } catch (e: IllegalArgumentException) {
            System.err.println("Argument error: ${e.message}")
            System.err.print(DaemonConfig.usage())
            System.exit(2)
            return
        }

        ensureMainLooperPrepared()
        HiddenApiCompat.exemptHiddenApis()

        val startTimeMs = System.currentTimeMillis()
        val shutdownLatch = CountDownLatch(1)
        val shuttingDown = AtomicBoolean(false)

        val worker: ScheduledExecutorService = Executors.newSingleThreadScheduledExecutor { runnable ->
            Thread(runnable, "shadow-diff-worker").apply { isDaemon = true }
        }

        val host = UiAutomationHost(config)
        val collector = ShadowTreeCollector(config)
        val differ = ShadowTreeDiffer()
        val encoder = NdjsonWireEncoder()
        val seqCounter = AtomicLong(0L)

        // Worker-thread confined writes, lock-free reads for immediate client hello/snapshot & heartbeats
        val currentSnapshot = AtomicReference<ShadowTreeSnapshot?>(null)

        lateinit var server: DaemonTcpServer
        lateinit var eventListener: AccessibilityEventListener

        fun shutdown(reason: String) {
            if (!shuttingDown.compareAndSet(false, true)) return
            if (config.verbose) {
                System.err.println("[ShadowGraph] Shutting down ($reason)...")
            }
            try {
                server.close()
            } catch (_: Throwable) {
            }
            try {
                host.disconnect()
            } catch (_: Throwable) {
            }
            try {
                worker.shutdownNow()
            } catch (_: Throwable) {
            }
            shutdownLatch.countDown()
        }

        fun submitWorker(task: () -> Unit) {
            if (shuttingDown.get() || worker.isShutdown) return
            try {
                worker.execute(task)
            } catch (_: RejectedExecutionException) {
            }
        }

        fun collectAndBroadcast(
            forceSnapshot: Boolean,
            targetSession: ClientSession?,
            reasonOverride: String?,
            eventType: Int?,
            eventPackage: String?
        ) {
            val uia = host.uiAutomation ?: return
            try {
                val seq = seqCounter.incrementAndGet()
                val next = collector.collect(seq, uia)
                val prev = currentSnapshot.get()

                if (targetSession != null) {
                    // Explicit single-client snapshot / resync request
                    val res = differ.diff(prev, next, forceSnapshot = false)
                    currentSnapshot.set(next)
                    when (res) {
                        is TreeDiffResult.FullSnapshot -> {
                            // Tree switched for everyone; broadcast full snapshot to other clients
                            server.broadcastSnapshot(next, res.reason, excludeSession = targetSession)
                            server.sendSnapshot(targetSession, next, reasonOverride ?: res.reason)
                        }
                        is TreeDiffResult.IncrementalDiff -> {
                            // Broadcast diff to existing clients, send full snapshot to requesting client
                            server.broadcastDiff(res, eventType, eventPackage, excludeSession = targetSession)
                            server.sendSnapshot(targetSession, next, reasonOverride ?: "requested")
                        }
                        TreeDiffResult.NoOp -> {
                            server.sendSnapshot(targetSession, next, reasonOverride ?: "requested")
                        }
                    }
                    return
                }

                val diffResult = differ.diff(prev, next, forceSnapshot = forceSnapshot)
                when (diffResult) {
                    TreeDiffResult.NoOp -> {
                        // Suppress empty no-op diff
                    }
                    is TreeDiffResult.FullSnapshot -> {
                        currentSnapshot.set(next)
                        server.broadcastSnapshot(next, reasonOverride ?: diffResult.reason)
                    }
                    is TreeDiffResult.IncrementalDiff -> {
                        currentSnapshot.set(next)
                        server.broadcastDiff(diffResult, eventType, eventPackage)
                    }
                }
            } catch (t: Throwable) {
                System.err.println("[ShadowGraph] Collection error: ${t.javaClass.simpleName}: ${t.message}")
            }
        }

        server = DaemonTcpServer(
            port = config.port,
            queueCapacity = config.clientQueueCapacity,
            encoder = encoder,
            deferBroadcastUntilSnapshot = true,
            listener = object : DaemonTcpServer.Listener {
                override fun onClientConnected(session: ClientSession) {
                    val hello = WireHello(
                        protocolVersion = 1,
                        format = encoder.formatName,
                        sdkInt = Build.VERSION.SDK_INT,
                        deviceModel = Build.MODEL ?: "Android",
                        daemonPid = Process.myPid().toLong()
                    )
                    server.sendHello(session, hello)
                    submitWorker {
                        if (session.isClosed || shuttingDown.get()) return@submitWorker
                        val cached = currentSnapshot.get()
                        if (cached != null) {
                            server.sendSnapshot(session, cached, reason = "initial")
                        } else {
                            collectAndBroadcast(
                                forceSnapshot = true,
                                targetSession = session,
                                reasonOverride = "initial",
                                eventType = null,
                                eventPackage = null
                            )
                        }
                    }
                }

                override fun onCommand(session: ClientSession, command: InboundCommand) {
                    when (command) {
                        InboundCommand.Snapshot -> {
                            submitWorker {
                                collectAndBroadcast(
                                    forceSnapshot = true,
                                    targetSession = session,
                                    reasonOverride = "requested",
                                    eventType = null,
                                    eventPackage = null
                                )
                            }
                        }
                        InboundCommand.Ping -> {
                            server.sendPong(
                                session,
                                WirePong(
                                    timestampMs = System.currentTimeMillis(),
                                    seq = seqCounter.get()
                                )
                            )
                        }
                        is InboundCommand.SetDebounce -> {
                            eventListener.updateDebounceMs(command.debounceMs)
                        }
                        InboundCommand.Shutdown -> {
                            shutdown("client_command")
                        }
                        is InboundCommand.Unknown -> {
                            server.sendError(
                                session,
                                WireError(
                                    code = "invalid_command",
                                    message = command.reason,
                                    timestampMs = System.currentTimeMillis()
                                )
                            )
                        }
                    }
                }

                override fun onResyncRequested(session: ClientSession) {
                    val cached = currentSnapshot.get()
                    if (cached != null) {
                        server.sendSnapshot(session, cached, reason = "resync")
                    } else {
                        submitWorker {
                            collectAndBroadcast(
                                forceSnapshot = true,
                                targetSession = session,
                                reasonOverride = "resync",
                                eventType = null,
                                eventPackage = null
                            )
                        }
                    }
                }

                override fun onServerError(error: Throwable) {
                    System.err.println("[ShadowGraph] TCP server error: ${error.message}")
                }
            }
        )

        eventListener = AccessibilityEventListener(
            workerExecutor = worker,
            initialDebounceMs = config.debounceMs,
            onCollectRequested = { urgent, eventType, eventPackage ->
                collectAndBroadcast(
                    forceSnapshot = false,
                    targetSession = null,
                    reasonOverride = if (urgent) "window_event" else null,
                    eventType = eventType,
                    eventPackage = eventPackage
                )
            }
        )

        Runtime.getRuntime().addShutdownHook(
            Thread({ shutdown("jvm_shutdown_hook") }, "shadow-shutdown-hook")
        )

        try {
            val uia = host.connect()
            server.start()
            uia.setOnAccessibilityEventListener(eventListener)

            submitWorker {
                collectAndBroadcast(
                    forceSnapshot = true,
                    targetSession = null,
                    reasonOverride = "initial",
                    eventType = null,
                    eventPackage = null
                )
            }

            if (!shuttingDown.get() && !worker.isShutdown) {
                try {
                    worker.scheduleAtFixedRate({
                        if (shuttingDown.get()) return@scheduleAtFixedRate
                        val snap = currentSnapshot.get()
                        val now = System.currentTimeMillis()
                        server.broadcastHeartbeat(
                            seq = seqCounter.get(),
                            timestampMs = now,
                            uptimeMs = now - startTimeMs,
                            activePackage = snap?.activePackage ?: "",
                            activeWindowId = snap?.activeWindowId ?: -1
                        )
                    }, config.heartbeatMs, config.heartbeatMs, TimeUnit.MILLISECONDS)
                } catch (_: RejectedExecutionException) {
                }
            }

            // Structured readiness signal for macOS host callers (Swift ADBConnectKit / deploy.sh)
            if (!shuttingDown.get()) {
                System.out.println("SHADOWGRAPH_DAEMON_READY port=${server.boundPort} pid=${Process.myPid()} sdk=${Build.VERSION.SDK_INT}")
                System.out.flush()
            }

            // Watch stdin EOF so dropping adb shell tears down UiAutomation cleanly
            if (config.watchStdin && !shuttingDown.get()) {
                Thread({
                    try {
                        val buf = ByteArray(64)
                        while (System.`in`.read(buf) != -1 && !shuttingDown.get()) {
                            // Ignore stdin bytes; only care about EOF
                        }
                    } catch (_: Throwable) {
                    } finally {
                        shutdown("stdin_eof")
                    }
                }, "shadow-stdin-watchdog").apply {
                    isDaemon = true
                    start()
                }
            }

            shutdownLatch.await()
            System.exit(0)
        } catch (t: Throwable) {
            System.err.println("[ShadowGraph] Fatal startup error: ${t.javaClass.name}: ${t.message}")
            t.printStackTrace(System.err)
            shutdown("fatal_error")
            System.exit(1)
        }
    }

    @Suppress("DEPRECATION")
    private fun ensureMainLooperPrepared() {
        try {
            if (Looper.getMainLooper() == null) {
                Looper.prepareMainLooper()
            }
        } catch (_: Throwable) {
        }
    }
}
