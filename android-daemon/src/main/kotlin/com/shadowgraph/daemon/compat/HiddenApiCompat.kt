package com.shadowgraph.daemon.compat

import android.os.Build

/**
 * Exempts all hidden/TestApi Android framework APIs for the current process
 * (required on Android 9+ / SDK 28–37 when running via app_process under shell UID 2000).
 */
object HiddenApiCompat {
    @Volatile
    private var exempted = false

    fun exemptHiddenApis(): Boolean {
        if (exempted) return true
        if (Build.VERSION.SDK_INT < 28) {
            exempted = true
            return true
        }
        return try {
            val vmRuntimeClass = Class.forName("dalvik.system.VMRuntime")
            val getRuntimeMethod = vmRuntimeClass.getDeclaredMethod("getRuntime")
            val runtime = getRuntimeMethod.invoke(null)
            val setExemptionsMethod = vmRuntimeClass.getDeclaredMethod(
                "setHiddenApiExemptions",
                Array<String>::class.java
            )
            setExemptionsMethod.invoke(runtime, arrayOf("L"))
            exempted = true
            true
        } catch (t: Throwable) {
            System.err.println("[ShadowGraph] HiddenApiCompat warning: ${t.javaClass.simpleName}: ${t.message}")
            false
        }
    }
}
