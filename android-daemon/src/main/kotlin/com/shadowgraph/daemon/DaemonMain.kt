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
import com.shadowgraph.daemon.input.InputInjector
import com.shadowgraph.daemon.transport.ClientSession
import com.shadowgraph.daemon.transport.DaemonTcpServer
import com.shadowgraph.daemon.transport.InboundCommand
import com.shadowgraph.daemon.transport.NdjsonWireEncoder
import com.shadowgraph.daemon.transport.WireError
import com.shadowgraph.daemon.transport.WireHello
import com.shadowgraph.daemon.transport.WireInputResult
import com.shadowgraph.daemon.transport.WirePong
import com.shadowgraph.daemon.transport.WireSecureScreen
import java.util.concurrent.CountDownLatch
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.RejectedExecutionException
import java.util.concurrent.ScheduledExecutorService
import java.util.concurrent.ScheduledFuture
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
        val inputWorker: ExecutorService = Executors.newSingleThreadExecutor { runnable ->
            Thread(runnable, "shadow-input-worker").apply { isDaemon = true }
        }

        val host = UiAutomationHost(config)
        val collector = ShadowTreeCollector(config)
        val differ = ShadowTreeDiffer()
        val encoder = NdjsonWireEncoder()
        val seqCounter = AtomicLong(0L)

        // Worker-thread confined writes, lock-free reads for immediate client hello/snapshot & heartbeats
        val currentSnapshot = AtomicReference<ShadowTreeSnapshot?>(null)
        val secureScreenActive = AtomicBoolean(false)
        val secureScreenReason = AtomicReference<String?>(null)
        val pendingSecureCheck = AtomicReference<ScheduledFuture<*>?>(null)

        lateinit var server: DaemonTcpServer
        lateinit var eventListener: AccessibilityEventListener

        fun emitSecureScreenTransition(active: Boolean, reason: String, snapshot: ShadowTreeSnapshot) {
            val code = if (active) "SECURE_SCREEN_ACTIVE" else "SECURE_SCREEN_CLEARED"
            secureScreenReason.set(if (active) reason else null)
            server.broadcastSecureScreen(
                WireSecureScreen(
                    code = code,
                    active = active,
                    reason = reason,
                    activePackage = snapshot.activePackage,
                    timestampMs = snapshot.timestampMs
                )
            )
        }

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
                inputWorker.shutdownNow()
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

        fun submitInput(session: ClientSession, id: Long, cmdName: String, task: () -> Unit) {
            if (shuttingDown.get() || inputWorker.isShutdown) {
                server.sendInputResult(
                    session,
                    WireInputResult(
                        id = id,
                        cmd = cmdName,
                        ok = false,
                        error = "daemon_shutting_down",
                        elapsedMs = 0L,
                        timestampMs = System.currentTimeMillis()
                    )
                )
                return
            }
            try {
                inputWorker.execute(task)
            } catch (_: RejectedExecutionException) {
                server.sendInputResult(
                    session,
                    WireInputResult(
                        id = id,
                        cmd = cmdName,
                        ok = false,
                        error = "input_executor_rejected",
                        elapsedMs = 0L,
                        timestampMs = System.currentTimeMillis()
                    )
                )
            }
        }

        fun evaluateSecureScreenState(snapshot: ShadowTreeSnapshot) {
            if (shuttingDown.get()) return
            if (snapshot.secureScreenActive) {
                val reason = snapshot.secureScreenReason ?: "empty_accessibility_tree"
                if (reason == "biometric_prompt") {
                    pendingSecureCheck.getAndSet(null)?.cancel(false)
                    if (secureScreenActive.compareAndSet(false, true) || secureScreenReason.get() != reason) {
                        emitSecureScreenTransition(active = true, reason = reason, snapshot = snapshot)
                    }
                    return
                }
                if (secureScreenActive.get()) return
                if (pendingSecureCheck.get() != null) return
                try {
                    val future = worker.schedule({
                        pendingSecureCheck.set(null)
                        if (shuttingDown.get()) return@schedule
                        val uia = host.uiAutomation ?: return@schedule
                        val recheckSeq = seqCounter.incrementAndGet()
                        val recheck = collector.collect(recheckSeq, uia)
                        if (recheck.secureScreenActive) {
                            currentSnapshot.set(recheck)
                            if (secureScreenActive.compareAndSet(false, true)) {
                                emitSecureScreenTransition(
                                    active = true,
                                    reason = recheck.secureScreenReason ?: reason,
                                    snapshot = recheck
                                )
                            }
                        }
                    }, 250L, TimeUnit.MILLISECONDS)
                    pendingSecureCheck.set(future)
                } catch (_: RejectedExecutionException) {
                }
            } else {
                pendingSecureCheck.getAndSet(null)?.cancel(false)
                if (secureScreenActive.compareAndSet(true, false)) {
                    emitSecureScreenTransition(active = false, reason = "tree_restored", snapshot = snapshot)
                }
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
                    evaluateSecureScreenState(next)
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
                evaluateSecureScreenState(next)
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
                        daemonPid = Process.myPid().toLong(),
                        capabilities = listOf("input")
                    )
                    server.sendHello(session, hello)
                    submitWorker {
                        if (session.isClosed || shuttingDown.get()) return@submitWorker
                        val cached = currentSnapshot.get()
                        if (cached != null) {
                            server.sendSnapshot(session, cached, reason = "initial")
                            if (secureScreenActive.get()) {
                                server.sendSecureScreen(
                                    session,
                                    WireSecureScreen(
                                        code = "SECURE_SCREEN_ACTIVE",
                                        active = true,
                                        reason = secureScreenReason.get() ?: "flag_secure_null_root",
                                        activePackage = cached.activePackage,
                                        timestampMs = System.currentTimeMillis()
                                    )
                                )
                            }
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
                        is InboundCommand.Tap -> {
                            submitInput(session, command.id, "tap") {
                                val uia = host.uiAutomation
                                val res = if (uia != null) {
                                    InputInjector.injectTap(uia, command.x, command.y)
                                } else {
                                    com.shadowgraph.daemon.input.InputExecutionResult(
                                        ok = false,
                                        error = "uiautomation_unavailable",
                                        elapsedMs = 0L
                                    )
                                }
                                server.sendInputResult(
                                    session,
                                    WireInputResult(
                                        id = command.id,
                                        cmd = "tap",
                                        ok = res.ok,
                                        error = res.error,
                                        elapsedMs = res.elapsedMs,
                                        timestampMs = System.currentTimeMillis()
                                    )
                                )
                            }
                        }
                        is InboundCommand.Swipe -> {
                            submitInput(session, command.id, "swipe") {
                                val uia = host.uiAutomation
                                val res = if (uia != null) {
                                    InputInjector.injectSwipe(
                                        uia = uia,
                                        x1 = command.x1,
                                        y1 = command.y1,
                                        x2 = command.x2,
                                        y2 = command.y2,
                                        durationMs = command.durationMs,
                                        holdMs = command.holdMs
                                    )
                                } else {
                                    com.shadowgraph.daemon.input.InputExecutionResult(
                                        ok = false,
                                        error = "uiautomation_unavailable",
                                        elapsedMs = 0L
                                    )
                                }
                                server.sendInputResult(
                                    session,
                                    WireInputResult(
                                        id = command.id,
                                        cmd = "swipe",
                                        ok = res.ok,
                                        error = res.error,
                                        elapsedMs = res.elapsedMs,
                                        timestampMs = System.currentTimeMillis()
                                    )
                                )
                            }
                        }
                        is InboundCommand.Keyevent -> {
                            submitInput(session, command.id, "keyevent") {
                                val uia = host.uiAutomation
                                val res = if (uia != null) {
                                    InputInjector.injectKeyevent(uia, command.keycode)
                                } else {
                                    com.shadowgraph.daemon.input.InputExecutionResult(
                                        ok = false,
                                        error = "uiautomation_unavailable",
                                        elapsedMs = 0L
                                    )
                                }
                                server.sendInputResult(
                                    session,
                                    WireInputResult(
                                        id = command.id,
                                        cmd = "keyevent",
                                        ok = res.ok,
                                        error = res.error,
                                        elapsedMs = res.elapsedMs,
                                        timestampMs = System.currentTimeMillis()
                                    )
                                )
                            }
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
