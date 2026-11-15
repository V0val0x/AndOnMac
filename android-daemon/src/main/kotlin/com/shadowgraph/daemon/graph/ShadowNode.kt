package com.shadowgraph.daemon.graph

/**
 * Immutable UI node representation aligned 1:1 with AndroidMCPKit's `AndroidUINode`
 * while carrying structural identity (`nodeId`, `parentId`, `windowId`) and extended
 * accessibility state flags for incremental diffing.
 *
 * Coordinates are stored as raw ints (`left`, `top`, `right`, `bottom`) so tree
 * collection and diffing avoid `[x1,y1][x2,y2]` String allocations in the hot path.
 */
data class ShadowNode(
    val nodeId: Long,
    val parentId: Long?,
    val windowId: Int,
    val index: Int,
    val childIndex: Int,
    val depth: Int,
    val packageName: String,
    val className: String,
    val resourceId: String,
    val text: String,
    val contentDesc: String,
    val left: Int,
    val top: Int,
    val right: Int,
    val bottom: Int,
    val clickable: Boolean,
    val scrollable: Boolean,
    val editable: Boolean,
    val focused: Boolean,
    val checked: Boolean,
    val enabled: Boolean,
    val visible: Boolean
) {
    val centerX: Int get() = (left + right) / 2
    val centerY: Int get() = (top + bottom) / 2

    fun boundsEquals(other: ShadowNode): Boolean =
        left == other.left &&
            top == other.top &&
            right == other.right &&
            bottom == other.bottom

    /**
     * Bitmask of fields that differ between `this` (previous) and `next` (current).
     * Returns 0 when all tracked properties are identical.
     */
    fun diffMask(next: ShadowNode): Int {
        var mask = 0
        if (parentId != next.parentId) mask = mask or PATCH_PARENT
        if (index != next.index || childIndex != next.childIndex || depth != next.depth) {
            mask = mask or PATCH_ORDER
        }
        if (text != next.text) mask = mask or PATCH_TEXT
        if (contentDesc != next.contentDesc) mask = mask or PATCH_CONTENT_DESC
        if (resourceId != next.resourceId) mask = mask or PATCH_RESOURCE_ID
        if (className != next.className || packageName != next.packageName) {
            mask = mask or PATCH_CLASS
        }
        if (!boundsEquals(next)) mask = mask or PATCH_BOUNDS
        if (flagsBitset() != next.flagsBitset()) mask = mask or PATCH_FLAGS
        return mask
    }

    fun flagsBitset(): Int {
        var bits = 0
        if (clickable) bits = bits or 1
        if (scrollable) bits = bits or (1 shl 1)
        if (editable) bits = bits or (1 shl 2)
        if (focused) bits = bits or (1 shl 3)
        if (checked) bits = bits or (1 shl 4)
        if (enabled) bits = bits or (1 shl 5)
        if (visible) bits = bits or (1 shl 6)
        return bits
    }

    companion object {
        const val PATCH_PARENT = 1 shl 0
        const val PATCH_ORDER = 1 shl 1
        const val PATCH_TEXT = 1 shl 2
        const val PATCH_CONTENT_DESC = 1 shl 3
        const val PATCH_RESOURCE_ID = 1 shl 4
        const val PATCH_CLASS = 1 shl 5
        const val PATCH_BOUNDS = 1 shl 6
        const val PATCH_FLAGS = 1 shl 7

        /**
         * Extracts the short class name matching AndroidUITreeParser.swift:
         * `className.split(".").last`
         */
        fun shortClassName(rawClassName: CharSequence?): String {
            if (rawClassName == null || rawClassName.isEmpty()) return ""
            val str = rawClassName.toString()
            val dotIdx = str.lastIndexOf('.')
            return if (dotIdx >= 0 && dotIdx + 1 < str.length) {
                str.substring(dotIdx + 1)
            } else {
                str
            }
        }
    }
}
