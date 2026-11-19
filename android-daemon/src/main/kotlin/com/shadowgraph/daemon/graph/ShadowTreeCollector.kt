package com.shadowgraph.daemon.graph

import android.app.UiAutomation
import android.graphics.Rect
import android.os.Build
import android.view.accessibility.AccessibilityNodeInfo
import android.view.accessibility.AccessibilityWindowInfo
import com.shadowgraph.daemon.config.DaemonConfig
import java.lang.reflect.Method

/**
 * Traverses Android's live `UiAutomation` window & accessibility hierarchy iteratively,
 * producing an immutable [ShadowTreeSnapshot] while recycling all acquired nodes safely.
 */
class ShadowTreeCollector(private val config: DaemonConfig) {
    private data class StackEntry(
        val node: AccessibilityNodeInfo,
        val parentEmittedId: Long?,
        val structuralParentHash: Long,
        val childIndex: Int,
        val depth: Int,
        val windowId: Int
    )

    private val rectScratch = Rect()
    private val stackScratch = ArrayList<StackEntry>(128)
    private val seenIdsScratch = HashSet<Long>(256)

    private val getSourceNodeIdMethod: Method? = try {
        AccessibilityNodeInfo::class.java.getDeclaredMethod("getSourceNodeId").apply {
            isAccessible = true
        }.also {
            if (config.verbose) {
                System.err.println("[ShadowGraph] Resolved AccessibilityNodeInfo.getSourceNodeId()")
            }
        }
    } catch (t: Throwable) {
        if (config.verbose) {
            System.err.println("[ShadowGraph] getSourceNodeId() unavailable (${t.javaClass.simpleName}); using structural hash")
        }
        null
    }

    fun collect(seq: Long, uiAutomation: UiAutomation): ShadowTreeSnapshot {
        val timestampNs = System.nanoTime()
        val timestampMs = System.currentTimeMillis()
        val nodes = ArrayList<ShadowNode>(128)
        val nodesById = LinkedHashMap<Long, ShadowNode>(256)
        seenIdsScratch.clear()

        var bestAnyPackage = ""
        var bestAnyWindowId = -1
        var bestAnyPriority = -1

        var bestAppPackage = ""
        var bestAppWindowId = -1
        var bestAppPriority = -1

        var hasNullRootAppWindow = false

        val windows: List<AccessibilityWindowInfo> = try {
            uiAutomation.windows ?: emptyList()
        } catch (_: Throwable) {
            emptyList()
        }

        if (windows.isNotEmpty()) {
            for (i in 0 until windows.size) {
                val window = windows[i]
                try {
                    val winId = window.id
                    val isApp = window.type == AccessibilityWindowInfo.TYPE_APPLICATION
                    val isActive = window.isActive
                    val isFocused = window.isFocused
                    val priority = (if (isActive) 4 else 0) +
                        (if (isFocused) 2 else 0) +
                        (if (isApp) 1 else 0)

                    val root = window.root
                    if (root != null) {
                        val rootPkg = root.packageName?.toString()?.trim().orEmpty()
                        if (priority > bestAnyPriority) {
                            bestAnyPriority = priority
                            bestAnyWindowId = winId
                            if (rootPkg.isNotEmpty()) {
                                bestAnyPackage = rootPkg
                            }
                        } else if (bestAnyPackage.isEmpty() && rootPkg.isNotEmpty()) {
                            bestAnyPackage = rootPkg
                        }

                        if (isApp && rootPkg.isNotEmpty() && rootPkg != SYSTEM_UI_PACKAGE && priority > bestAppPriority) {
                            bestAppPriority = priority
                            bestAppWindowId = winId
                            bestAppPackage = rootPkg
                        }

                        traverseWindowRoot(
                            root = root,
                            windowId = winId,
                            nodes = nodes,
                            nodesById = nodesById
                        )
                    } else if (isApp && (isActive || isFocused)) {
                        hasNullRootAppWindow = true
                    }
                } finally {
                    safeRecycleWindow(window)
                }
            }
        } else {
            val root = try {
                uiAutomation.rootInActiveWindow
            } catch (_: Throwable) {
                null
            }
            if (root != null) {
                bestAnyWindowId = root.windowId
                bestAnyPackage = root.packageName?.toString()?.trim().orEmpty()
                if (bestAnyPackage.isNotEmpty() && bestAnyPackage != SYSTEM_UI_PACKAGE) {
                    bestAppWindowId = bestAnyWindowId
                    bestAppPackage = bestAnyPackage
                }
                traverseWindowRoot(
                    root = root,
                    windowId = bestAnyWindowId,
                    nodes = nodes,
                    nodesById = nodesById
                )
            } else {
                hasNullRootAppWindow = true
            }
        }

        // Overlay masking (#3): anchor snapshot metadata to the visible foreground app window
        // whenever a heads-up notification or transient systemui window overlays it.
        val activePackage = if (bestAppPackage.isNotEmpty()) bestAppPackage else bestAnyPackage
        val activeWindowId = if (bestAppWindowId != -1) bestAppWindowId else bestAnyWindowId

        // Secure screen / FLAG_SECURE / biometric detection (#7)
        var nonSystemUiNodeCount = 0
        var biometricPromptActive = false
        for (i in 0 until nodes.size) {
            val n = nodes[i]
            if (n.packageName != SYSTEM_UI_PACKAGE && !n.resourceId.startsWith("$SYSTEM_UI_PACKAGE:")) {
                nonSystemUiNodeCount++
            }
            if (!biometricPromptActive && n.visible && isBiometricOrCredentialNode(n)) {
                biometricPromptActive = true
            }
        }

        val emptyTree = nodes.isEmpty() || (hasNullRootAppWindow && nonSystemUiNodeCount == 0)
        val secureScreenActive = biometricPromptActive || emptyTree
        val secureScreenReason = when {
            biometricPromptActive -> "biometric_prompt"
            hasNullRootAppWindow -> "flag_secure_null_root"
            nodes.isEmpty() -> "empty_accessibility_tree"
            else -> null
        }

        return ShadowTreeSnapshot(
            seq = seq,
            timestampNs = timestampNs,
            timestampMs = timestampMs,
            activePackage = activePackage,
            activeWindowId = activeWindowId,
            nodes = nodes,
            nodesById = nodesById,
            secureScreenActive = secureScreenActive,
            secureScreenReason = secureScreenReason
        )
    }

    private fun isBiometricOrCredentialNode(node: ShadowNode): Boolean {
        val rid = node.resourceId.lowercase()
        val cls = node.className.lowercase()
        if (cls.contains("biometricprompt") || cls.contains("lockpatternview") || cls.contains("pinentry")) {
            return true
        }
        val isCredentialHost = node.packageName == SYSTEM_UI_PACKAGE ||
            node.packageName == "com.android.settings" ||
            rid.startsWith("$SYSTEM_UI_PACKAGE:")
        if (!isCredentialHost) return false
        return rid.contains("biometric") ||
            rid.contains("auth_credential") ||
            rid.contains("keyguard_password") ||
            rid.contains("pinentry") ||
            rid.contains("pin_entry") ||
            rid.contains("lockpattern") ||
            rid.contains("lock_pattern")
    }

    private fun traverseWindowRoot(
        root: AccessibilityNodeInfo,
        windowId: Int,
        nodes: ArrayList<ShadowNode>,
        nodesById: LinkedHashMap<Long, ShadowNode>
    ) {
        stackScratch.clear()
        stackScratch.add(
            StackEntry(
                node = root,
                parentEmittedId = null,
                structuralParentHash = mix64(windowId.toLong()),
                childIndex = 0,
                depth = 0,
                windowId = windowId
            )
        )

        while (stackScratch.isNotEmpty()) {
            val entry = stackScratch.removeAt(stackScratch.size - 1)
            val node = entry.node
            try {
                if (nodes.size >= MAX_NODES_SAFETY_CAP) {
                    continue
                }

                val visible = node.isVisibleToUser
                if (!config.includeInvisible && !visible) {
                    continue
                }

                node.getBoundsInScreen(rectScratch)
                val text = node.text?.toString()?.trim().orEmpty()
                val contentDesc = node.contentDescription?.toString()?.trim().orEmpty()
                val resourceId = node.viewIdResourceName?.trim().orEmpty()
                val packageName = node.packageName?.toString()?.trim().orEmpty()
                val className = ShadowNode.shortClassName(node.className)

                val clickable = node.isClickable
                val scrollable = node.isScrollable
                val editable = node.isEditable
                val focused = node.isFocused
                @Suppress("DEPRECATION")
                val checked = node.isChecked
                val enabled = node.isEnabled

                val structuralHash = computeStructuralHash(
                    parentHash = entry.structuralParentHash,
                    childIndex = entry.childIndex,
                    className = className,
                    resourceId = resourceId
                )
                val nodeId = resolveUniqueNodeId(
                    node = node,
                    windowId = entry.windowId,
                    structuralHash = structuralHash
                )

                val isMeaningful = clickable || scrollable || editable || focused ||
                    text.isNotEmpty() || contentDesc.isNotEmpty() || resourceId.isNotEmpty()

                val emittedParentId: Long?
                if (!config.meaningfulOnly || isMeaningful) {
                    val emitted = ShadowNode(
                        nodeId = nodeId,
                        parentId = entry.parentEmittedId,
                        windowId = entry.windowId,
                        index = nodes.size,
                        childIndex = entry.childIndex,
                        depth = entry.depth,
                        packageName = packageName,
                        className = className,
                        resourceId = resourceId,
                        text = text,
                        contentDesc = contentDesc,
                        left = rectScratch.left,
                        top = rectScratch.top,
                        right = rectScratch.right,
                        bottom = rectScratch.bottom,
                        clickable = clickable,
                        scrollable = scrollable,
                        editable = editable,
                        focused = focused,
                        checked = checked,
                        enabled = enabled,
                        visible = visible
                    )
                    nodes.add(emitted)
                    nodesById[nodeId] = emitted
                    emittedParentId = nodeId
                } else {
                    emittedParentId = entry.parentEmittedId
                }

                if (entry.depth < config.maxDepth) {
                    val childCount = node.childCount
                    // Push children in reverse order so child 0 is popped first (standard DFS order)
                    for (cIdx in childCount - 1 downTo 0) {
                        val child = try {
                            node.getChild(cIdx)
                        } catch (_: Throwable) {
                            null
                        }
                        if (child != null) {
                            stackScratch.add(
                                StackEntry(
                                    node = child,
                                    parentEmittedId = emittedParentId,
                                    structuralParentHash = structuralHash,
                                    childIndex = cIdx,
                                    depth = entry.depth + 1,
                                    windowId = entry.windowId
                                )
                            )
                        }
                    }
                }
            } finally {
                safeRecycleNode(node)
            }
        }
    }

    private fun resolveUniqueNodeId(
        node: AccessibilityNodeInfo,
        windowId: Int,
        structuralHash: Long
    ): Long {
        var candidate = structuralHash
        val method = getSourceNodeIdMethod
        if (method != null) {
            val rawSourceId = try {
                (method.invoke(node) as? Long) ?: -1L
            } catch (_: Throwable) {
                -1L
            }
            if (rawSourceId != -1L && rawSourceId != Long.MAX_VALUE) {
                candidate = mix64((windowId.toLong() shl 32) xor rawSourceId)
            }
        }

        // Guard against hash collisions or virtual views sharing sourceNodeId
        while (!seenIdsScratch.add(candidate)) {
            candidate = mix64(candidate xor structuralHash xor 0x9E3779B97F4A7C15UL.toLong())
        }
        return candidate
    }

    private fun computeStructuralHash(
        parentHash: Long,
        childIndex: Int,
        className: String,
        resourceId: String
    ): Long {
        var h = parentHash * FNV_PRIME
        h = (h xor childIndex.toLong()) * FNV_PRIME
        for (i in 0 until className.length) {
            h = (h xor className[i].code.toLong()) * FNV_PRIME
        }
        if (resourceId.isNotEmpty()) {
            h = (h xor 0xFFL) * FNV_PRIME
            for (i in 0 until resourceId.length) {
                h = (h xor resourceId[i].code.toLong()) * FNV_PRIME
            }
        }
        return mix64(h)
    }

    @Suppress("DEPRECATION")
    private fun safeRecycleNode(node: AccessibilityNodeInfo) {
        if (Build.VERSION.SDK_INT < 34) {
            try {
                node.recycle()
            } catch (_: Throwable) {
            }
        }
    }

    @Suppress("DEPRECATION")
    private fun safeRecycleWindow(window: AccessibilityWindowInfo) {
        if (Build.VERSION.SDK_INT < 34) {
            try {
                window.recycle()
            } catch (_: Throwable) {
            }
        }
    }

    companion object {
        private const val SYSTEM_UI_PACKAGE = "com.android.systemui"
        private const val MAX_NODES_SAFETY_CAP = 4096
        private const val FNV_PRIME = 1099511628211L

        private fun mix64(zIn: Long): Long {
            var z = zIn
            z = (z xor (z ushr 30)) * -4658895280553007687L
            z = (z xor (z ushr 27)) * -7723592293110705685L
            return z xor (z ushr 31)
        }
    }
}
