package com.andonmac.companion

import android.app.Activity
import android.content.ComponentName
import android.content.Intent
import android.os.Bundle
import android.provider.Settings
import android.text.TextUtils
import android.widget.Button
import android.widget.TextView
import android.widget.Toast

class MainActivity : Activity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        val layout = android.widget.LinearLayout(this).apply {
            orientation = android.widget.LinearLayout.VERTICAL
            setPadding(60, 100, 60, 60)
        }

        val titleView = TextView(this).apply {
            text = "AndOnMac Companion"
            textSize = 24f
            setTypeface(null, android.graphics.Typeface.BOLD)
        }

        val statusView = TextView(this).apply {
            text = if (isNotificationServiceEnabled()) {
                "✅ Уведомления включены и зеркалируются на Mac"
            } else {
                "⚠️ Требуется доступ к уведомлениям для показа на Mac"
            }
            textSize = 16f
            setPadding(0, 30, 0, 40)
        }

        val button = Button(this).apply {
            text = "Открыть настройки доступа к уведомлениям"
            setOnClickListener {
                startActivity(Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS))
            }
        }

        layout.addView(titleView)
        layout.addView(statusView)
        layout.addView(button)

        setContentView(layout)
    }

    private fun isNotificationServiceEnabled(): Boolean {
        val pkgName = packageName
        val flat = Settings.Secure.getString(contentResolver, "enabled_notification_listeners")
        if (!TextUtils.isEmpty(flat)) {
            val names = flat.split(":".toRegex()).toTypedArray()
            for (name in names) {
                val cn = ComponentName.unflattenFromString(name)
                if (cn != null && TextUtils.equals(pkgName, cn.packageName)) {
                    return true
                }
            }
        }
        return false
    }
}
