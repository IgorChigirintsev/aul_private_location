package app.aul.aul

import android.content.Intent
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * Hosts the Flutter UI and exposes a control channel the UI uses to start/stop
 * the foreground reporting service. All reporting logic runs in the service's
 * background isolate; the UI only issues commands and reads status.
 */
class MainActivity : FlutterActivity() {
    private val controlChannel = "app.aul/control"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, controlChannel)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "startReporting" -> {
                        LocationService.start(
                            context = applicationContext,
                            intervalMs = (call.argument<Number>("interval_ms"))?.toLong() ?: 60_000,
                            displacementM = (call.argument<Number>("displacement_m"))?.toFloat() ?: 20f,
                            priority = call.argument<String>("priority") ?: "balanced",
                            notifText = call.argument<String>("notif_text") ?: "Sharing your location",
                        )
                        result.success(true)
                    }
                    "stopReporting" -> {
                        LocationService.stop(applicationContext)
                        result.success(true)
                    }
                    "isReporting" -> {
                        val enabled = applicationContext
                            .getSharedPreferences(LocationService.PREFS, MODE_PRIVATE)
                            .getBoolean(LocationService.KEY_ENABLED, false)
                        result.success(enabled)
                    }
                    else -> result.notImplemented()
                }
            }

        // Self-update: hand a SHA-256-verified APK to the system installer.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "app.aul/installer")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "installApk" -> {
                        val path = call.argument<String>("path")
                        if (path == null) {
                            result.error("no_path", "path required", null)
                        } else {
                            try {
                                installApk(path)
                                result.success(true)
                            } catch (e: Throwable) {
                                result.error("install_failed", e.message, null)
                            }
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun installApk(path: String) {
        val file = File(path)
        val uri = FileProvider.getUriForFile(this, "$packageName.fileprovider", file)
        val intent = Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(uri, "application/vnd.android.package-archive")
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        startActivity(intent)
    }
}
