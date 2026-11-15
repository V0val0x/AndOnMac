package com.shadowgraph.daemon.accessibility

import android.app.UiAutomation
import android.view.accessibility.AccessibilityEvent
import java.util.concurrent.RejectedExecutionException
import java.util.concurrent.ScheduledExecutorService
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong

/**
 * Listens to Android `UiAutomation.OnAccessibilityEventListener`, filters relevant UI mutations,
 * and coalesces high-frequency event bursts (e.g., 120 Hz scrolling) onto a single worker executor.
 */
class AccessibilityEventListener(
    private val workerExecutor: ScheduledExecutorService,
    initialDebounceMs: Long,
    private val onCollectRequested: (urgent: Boolean, eventType: Int?, eventPackage: String?) -> Unit
) : UiAutomation.OnAccessibilityEventListener {

    private val debounceMs = AtomicLong(initialDebounceMs)
    private val pendingDebounced = AtomicBoolean(false)
    private val pendingUrgent = AtomicBoolean(false)

    @Volatile
    private var lastEventType: Int? = null

    @Volatile
    private var lastEventPackage: String? = null

    fun updateDebounceMs(newDebounceMs: Long) {
        debounceMs.set(newDebounceMs)
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {
        if (event == null) return
        val eventType = event.eventType
        if (!isRelevantEvent(eventType)) return

        lastEventType = eventType
        val pkg = event.packageName?.toString()
        if (!pkg.isNullOrEmpty()) {
            lastEventPackage = pkg
        }

        if (workerExecutor.isShutdown) return

        val urgent = (eventType == AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED) ||
            (eventType == AccessibilityEvent.TYPE_WINDOWS_CHANGED)

        if (urgent) {
            if (pendingUrgent.compareAndSet(false, true)) {
                try {
                    workerExecutor.execute {
                        pendingUrgent.set(false)
                        pendingDebounced.set(false)
                        onCollectRequested(true, lastEventType, lastEventPackage)
                    }
                } catch (_: RejectedExecutionException) {
                    pendingUrgent.set(false)
                }
            }
        } else {
            val delay = debounceMs.get()
            if (delay <= 0L) {
                if (pendingUrgent.compareAndSet(false, true)) {
                    try {
                        workerExecutor.execute {
                            pendingUrgent.set(false)
                            onCollectRequested(false, lastEventType, lastEventPackage)
                        }
                    } catch (_: RejectedExecutionException) {
                        pendingUrgent.set(false)
                    }
                }
            } else if (pendingDebounced.compareAndSet(false, true)) {
                try {
                    workerExecutor.schedule({
                        pendingDebounced.set(false)
                        onCollectRequested(false, lastEventType, lastEventPackage)
                    }, delay, TimeUnit.MILLISECONDS)
                } catch (_: RejectedExecutionException) {
                    pendingDebounced.set(false)
                }
            }
        }
    }

    companion object {
        private const val RELEVANT_EVENT_MASK =
            AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED or
                AccessibilityEvent.TYPE_WINDOWS_CHANGED or
                AccessibilityEvent.TYPE_WINDOW_CONTENT_CHANGED or
                AccessibilityEvent.TYPE_VIEW_SCROLLED or
                AccessibilityEvent.TYPE_VIEW_TEXT_CHANGED or
                AccessibilityEvent.TYPE_VIEW_TEXT_SELECTION_CHANGED or
                AccessibilityEvent.TYPE_VIEW_CLICKED or
                AccessibilityEvent.TYPE_VIEW_SELECTED or
                AccessibilityEvent.TYPE_VIEW_FOCUSED

        fun isRelevantEvent(eventType: Int): Boolean = (eventType and RELEVANT_EVENT_MASK) != 0
    }
}
