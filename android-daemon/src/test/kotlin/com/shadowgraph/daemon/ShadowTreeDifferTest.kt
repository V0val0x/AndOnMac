package com.shadowgraph.daemon

import com.shadowgraph.daemon.graph.ShadowNode
import com.shadowgraph.daemon.graph.ShadowTreeDiffer
import com.shadowgraph.daemon.graph.ShadowTreeSnapshot
import com.shadowgraph.daemon.graph.TreeDiffResult
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertIs
import kotlin.test.assertTrue

class ShadowTreeDifferTest {
    private fun makeNode(
        id: Long,
        parentId: Long? = null,
        windowId: Int = 10,
        index: Int = 0,
        childIndex: Int = 0,
        depth: Int = 0,
        pkg: String = "com.android.settings",
        cls: String = "TextView",
        resourceId: String = "android:id/title",
        text: String = "Wi-Fi",
        contentDesc: String = "",
        left: Int = 0,
        top: Int = 100,
        right: Int = 500,
        bottom: Int = 200,
        clickable: Boolean = true,
        scrollable: Boolean = false
    ) = ShadowNode(
        nodeId = id,
        parentId = parentId,
        windowId = windowId,
        index = index,
        childIndex = childIndex,
        depth = depth,
        packageName = pkg,
        className = cls,
        resourceId = resourceId,
        text = text,
        contentDesc = contentDesc,
        left = left,
        top = top,
        right = right,
        bottom = bottom,
        clickable = clickable,
        scrollable = scrollable,
        editable = false,
        focused = false,
        checked = false,
        enabled = true,
        visible = true
    )

    private fun makeSnapshot(
        seq: Long,
        pkg: String = "com.android.settings",
        windowId: Int = 10,
        nodes: List<ShadowNode>
    ) = ShadowTreeSnapshot.fromNodes(
        seq = seq,
        timestampNs = seq * 1_000_000L,
        timestampMs = 1_700_000_000_000L + seq,
        activePackage = pkg,
        activeWindowId = windowId,
        nodes = nodes
    )

    @Test
    fun `emits FullSnapshot on initial frame and on forceSnapshot`() {
        val differ = ShadowTreeDiffer()
        val n1 = makeNode(id = 1L)
        val s1 = makeSnapshot(seq = 1L, nodes = listOf(n1))

        val r1 = differ.diff(null, s1)
        val full1 = assertIs<TreeDiffResult.FullSnapshot>(r1)
        assertEquals("initial", full1.reason)
        assertEquals(1, full1.snapshot.nodes.size)

        val s2 = makeSnapshot(seq = 2L, nodes = listOf(n1))
        val r2 = differ.diff(s1, s2, forceSnapshot = true)
        val full2 = assertIs<TreeDiffResult.FullSnapshot>(r2)
        assertEquals("requested", full2.reason)
    }

    @Test
    fun `suppresses NoOp when trees are identical`() {
        val differ = ShadowTreeDiffer()
        val s1 = makeSnapshot(seq = 1L, nodes = listOf(makeNode(1L), makeNode(2L, parentId = 1L, index = 1, childIndex = 0, depth = 1)))
        val s2 = makeSnapshot(seq = 2L, nodes = listOf(makeNode(1L), makeNode(2L, parentId = 1L, index = 1, childIndex = 0, depth = 1)))

        assertIs<TreeDiffResult.NoOp>(differ.diff(s1, s2))
    }

    @Test
    fun `emits FullSnapshot on package switch or window switch`() {
        val differ = ShadowTreeDiffer()
        val s1 = makeSnapshot(seq = 1L, pkg = "com.android.settings", windowId = 10, nodes = listOf(makeNode(1L)))
        val sPkg = makeSnapshot(seq = 2L, pkg = "com.whatsapp", windowId = 10, nodes = listOf(makeNode(1L, pkg = "com.whatsapp")))
        val sWin = makeSnapshot(seq = 3L, pkg = "com.android.settings", windowId = 25, nodes = listOf(makeNode(1L, windowId = 25)))

        val pkgRes = assertIs<TreeDiffResult.FullSnapshot>(differ.diff(s1, sPkg))
        assertEquals("package_switch", pkgRes.reason)

        val winRes = assertIs<TreeDiffResult.FullSnapshot>(differ.diff(s1, sWin))
        assertEquals("window_switch", winRes.reason)
    }

    @Test
    fun `computes incremental insert, update masks, and remove`() {
        val differ = ShadowTreeDiffer()
        val root = makeNode(id = 1L, index = 0, text = "")
        val childA = makeNode(id = 2L, parentId = 1L, index = 1, childIndex = 0, depth = 1, text = "Old")
        val childB = makeNode(id = 3L, parentId = 1L, index = 2, childIndex = 1, depth = 1, text = "DeleteMe")
        val s1 = makeSnapshot(seq = 1L, nodes = listOf(root, childA, childB))

        val childAUpdated = childA.copy(text = "New", top = 120, bottom = 220)
        val childCInserted = makeNode(id = 4L, parentId = 1L, index = 2, childIndex = 1, depth = 1, text = "Added")
        val s2 = makeSnapshot(seq = 2L, nodes = listOf(root, childAUpdated, childCInserted))

        val diff = assertIs<TreeDiffResult.IncrementalDiff>(differ.diff(s1, s2))
        assertEquals(1L, diff.baseSeq)
        assertEquals(2L, diff.seq)
        assertEquals(listOf(childCInserted), diff.inserted)
        assertEquals(listOf(3L), diff.removedIds)
        assertEquals(1, diff.updated.size)

        val patch = diff.updated.single()
        assertEquals(2L, patch.node.nodeId)
        assertTrue((patch.mask and ShadowNode.PATCH_TEXT) != 0)
        assertTrue((patch.mask and ShadowNode.PATCH_BOUNDS) != 0)
        assertEquals(0, patch.mask and ShadowNode.PATCH_FLAGS)
    }

    @Test
    fun `shortClassName matches AndroidUITreeParser convention`() {
        assertEquals("TextView", ShadowNode.shortClassName("android.widget.TextView"))
        assertEquals("Button", ShadowNode.shortClassName("Button"))
        assertEquals("", ShadowNode.shortClassName(null))
        assertEquals("", ShadowNode.shortClassName(""))
    }

    @Test
    fun `handles empty snapshots cleanly without crashing`() {
        val differ = ShadowTreeDiffer()
        val empty1 = makeSnapshot(seq = 1L, nodes = emptyList())
        val empty2 = makeSnapshot(seq = 2L, nodes = emptyList())

        assertIs<TreeDiffResult.FullSnapshot>(differ.diff(null, empty1))
        assertIs<TreeDiffResult.NoOp>(differ.diff(empty1, empty2))
    }
}
