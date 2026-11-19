package com.shadowgraph.daemon

import com.shadowgraph.daemon.graph.ShadowTreeCollector
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class ShadowTreeCollectorPrivacyTest {
    @Test
    fun `redacts entered password text and matching contentDesc while preserving distinct hints`() {
        val (t1, d1) = ShadowTreeCollector.redactNodeText(
            rawText = "SuperSecret123!",
            rawContentDesc = "SuperSecret123!",
            resourceId = "com.example:id/input",
            isPassword = true,
            editable = true,
            isShowingHint = false
        )
        assertEquals("***", t1)
        assertEquals("***", d1)

        val (t2, d2) = ShadowTreeCollector.redactNodeText(
            rawText = "MyPass42",
            rawContentDesc = "Password",
            resourceId = "com.example:id/input",
            isPassword = true,
            editable = true,
            isShowingHint = false
        )
        assertEquals("***", t2)
        assertEquals("Password", d2)
    }

    @Test
    fun `preserves empty password field description and API 26 hint text`() {
        val (tEmpty, dEmpty) = ShadowTreeCollector.redactNodeText(
            rawText = "",
            rawContentDesc = "Password",
            resourceId = "com.example:id/password",
            isPassword = true,
            editable = true,
            isShowingHint = false
        )
        assertEquals("", tEmpty)
        assertEquals("Password", dEmpty)

        val (tHint, dHint) = ShadowTreeCollector.redactNodeText(
            rawText = "Enter password",
            rawContentDesc = "Enter password",
            resourceId = "com.example:id/password",
            isPassword = true,
            editable = true,
            isShowingHint = true
        )
        assertEquals("Enter password", tHint)
        assertEquals("Enter password", dHint)
    }

    @Test
    fun `redacts editable fields with sensitive resourceIds regardless of isPassword flag`() {
        val sensitiveIds = listOf(
            "com.bank:id/user_password",
            "com.bank:id/passwd_edit",
            "com.bank:id/passcode_entry",
            "com.bank:id/pin_input_field",
            "com.bank:id/pinInput",
            "com.bank:id/card_cvv",
            "com.bank:id/cvc_box",
            "com.bank:id/security_code",
            "com.bank:id/securityCode"
        )
        for (rid in sensitiveIds) {
            assertTrue(ShadowTreeCollector.hasSensitiveResourceId(rid), "Expected sensitive: $rid")
            val (t, d) = ShadowTreeCollector.redactNodeText(
                rawText = "742",
                rawContentDesc = "742",
                resourceId = rid,
                isPassword = false,
                editable = true,
                isShowingHint = false
            )
            assertEquals("***", t, "Expected text redacted for $rid")
            assertEquals("***", d, "Expected matching contentDesc redacted for $rid")
        }

        // Hint text on sensitive editable field must stay visible
        val (tHint, dHint) = ShadowTreeCollector.redactNodeText(
            rawText = "CVV",
            rawContentDesc = "Security code",
            resourceId = "com.bank:id/cvv_input",
            isPassword = false,
            editable = true,
            isShowingHint = true
        )
        assertEquals("CVV", tHint)
        assertEquals("Security code", dHint)
    }

    @Test
    fun `does not redact non-editable labels or benign editable search fields`() {
        val (labelText, labelDesc) = ShadowTreeCollector.redactNodeText(
            rawText = "Password",
            rawContentDesc = "",
            resourceId = "com.bank:id/password_label",
            isPassword = false,
            editable = false,
            isShowingHint = false
        )
        assertEquals("Password", labelText)
        assertEquals("", labelDesc)

        // Package name containing 'cvc' should not trigger false positive when short id is benign
        assertFalse(ShadowTreeCollector.hasSensitiveResourceId("com.cvc.shop:id/search_query"))
        val (searchText, searchDesc) = ShadowTreeCollector.redactNodeText(
            rawText = "running shoes",
            rawContentDesc = "Search",
            resourceId = "com.cvc.shop:id/search_query",
            isPassword = false,
            editable = true,
            isShowingHint = false
        )
        assertEquals("running shoes", searchText)
        assertEquals("Search", searchDesc)
    }
}
