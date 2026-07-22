package app.aul.aul

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/**
 * Restarts reporting after a reboot or app update — but ONLY if the user had
 * reporting enabled. This never starts sharing on its own.
 */
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        when (intent.action) {
            Intent.ACTION_BOOT_COMPLETED,
            Intent.ACTION_MY_PACKAGE_REPLACED,
            "android.intent.action.QUICKBOOT_POWERON" -> {
                val prefs = context.getSharedPreferences(LocationService.PREFS, Context.MODE_PRIVATE)
                if (!prefs.getBoolean(LocationService.KEY_ENABLED, false)) return
                LocationService.start(
                    context = context,
                    intervalMs = prefs.getLong(LocationService.KEY_INTERVAL, 60_000),
                    displacementM = prefs.getFloat(LocationService.KEY_DISPLACEMENT, 20f),
                    priority = prefs.getString(LocationService.KEY_PRIORITY, "balanced")!!,
                    notifText = prefs.getString(LocationService.KEY_NOTIF, "Sharing your location")!!,
                )
            }
        }
    }
}
