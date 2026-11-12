package com.andonmac.companion

import android.app.Notification
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification
import org.json.JSONObject
import java.io.OutputStreamWriter
import java.net.InetSocketAddress
import java.net.Socket
import java.util.concurrent.Executors

class NotificationService : NotificationListenerService() {

    private val executor = Executors.newSingleThreadExecutor()
    private val macPort = 58241

    override fun onNotificationPosted(sbn: StatusBarNotification) {
        val notification = sbn.notification ?: return
        val extras = notification.extras ?: return
        
        val title = extras.getCharSequence(Notification.EXTRA_TITLE)?.toString() ?: ""
        val text = extras.getCharSequence(Notification.EXTRA_TEXT)?.toString() ?: ""
        
        // Skip empty system/ongoing notifications
        if (title.isBlank() && text.isBlank()) return
        if ((notification.flags and Notification.FLAG_ONGOING_EVENT) != 0) return

        val packageName = sbn.packageName
        val appName = try {
            val pm = packageManager
            val appInfo = pm.getApplicationInfo(packageName, 0)
            pm.getApplicationLabel(appInfo).toString()
        } catch (e: Exception) {
            packageName
        }

        val json = JSONObject().apply {
            put("id", "${sbn.id}_${sbn.postTime}")
            put("packageName", packageName)
            put("appName", appName)
            put("title", title)
            put("text", text)
            put("timestamp", sbn.postTime / 1000.0)
        }

        sendToMac(json.toString())
    }

    private fun sendToMac(payload: String) {
        executor.execute {
            // In USB reverse mode or wireless mode, the Mac can be reached at 127.0.0.1 (via adb reverse)
            // or the gateway IP on local Wi-Fi.
            val targetHosts = listOf("127.0.0.1", "10.0.2.2")
            for (host in targetHosts) {
                try {
                    Socket().use { socket ->
                        socket.connect(InetSocketAddress(host, macPort), 1000)
                        OutputStreamWriter(socket.getOutputStream(), "UTF-8").use { writer ->
                            writer.write(payload)
                            writer.flush()
                        }
                    }
                    break // Successfully delivered
                } catch (_: Exception) {
                    // Try next fallback or wait
                }
            }
        }
    }
}
