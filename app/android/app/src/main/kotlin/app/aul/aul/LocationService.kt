package app.aul.aul

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.location.Location
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.SystemClock
import androidx.core.app.NotificationCompat
import com.google.android.gms.location.FusedLocationProviderClient
import com.google.android.gms.location.LocationCallback
import com.google.android.gms.location.LocationRequest
import com.google.android.gms.location.LocationResult
import com.google.android.gms.location.LocationServices
import com.google.android.gms.location.Priority
import com.google.android.gms.tasks.CancellationTokenSource
import io.flutter.FlutterInjector
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodChannel

/**
 * Foreground location service (type=location). A reporter ALWAYS shows a visible
 * notification — there is no hidden mode (anti-stalking guarantee).
 *
 * It hosts a background FlutterEngine running the `aulLocationServiceMain` Dart
 * entrypoint so the tested Dart reporting pipeline (seal → offline queue → send)
 * runs even when the UI is gone or after a reboot. Each fix from
 * FusedLocationProvider is forwarded to that isolate over a MethodChannel.
 */
class LocationService : Service() {

    companion object {
        const val ACTION_START = "app.aul.action.START"
        const val ACTION_STOP = "app.aul.action.STOP"
        const val ACTION_PAUSE = "app.aul.action.PAUSE_1H"

        const val EXTRA_INTERVAL_MS = "interval_ms"
        const val EXTRA_DISPLACEMENT_M = "displacement_m"
        const val EXTRA_PRIORITY = "priority" // "high" | "balanced"
        const val EXTRA_NOTIF_TEXT = "notif_text"

        private const val CHANNEL_ID = "aul_reporting"
        private const val NOTIF_ID = 4201
        private const val BG_CHANNEL = "app.aul/bg"

        const val PREFS = "aul_service"
        const val KEY_ENABLED = "reporting_enabled"
        const val KEY_INTERVAL = "interval_ms"
        const val KEY_DISPLACEMENT = "displacement_m"
        const val KEY_PRIORITY = "priority"
        const val KEY_NOTIF = "notif_text"

        fun start(context: Context, intervalMs: Long, displacementM: Float, priority: String, notifText: String) {
            val i = Intent(context, LocationService::class.java).apply {
                action = ACTION_START
                putExtra(EXTRA_INTERVAL_MS, intervalMs)
                putExtra(EXTRA_DISPLACEMENT_M, displacementM)
                putExtra(EXTRA_PRIORITY, priority)
                putExtra(EXTRA_NOTIF_TEXT, notifText)
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(i)
            } else {
                context.startService(i)
            }
        }

        fun stop(context: Context) {
            context.startService(Intent(context, LocationService::class.java).apply { action = ACTION_STOP })
        }
    }

    private lateinit var fused: FusedLocationProviderClient
    private var engine: FlutterEngine? = null
    private var bgChannel: MethodChannel? = null
    private var callback: LocationCallback? = null
    private var notifText: String = "Sharing your location"

    private val handler = Handler(Looper.getMainLooper())
    private var refreshTick: Runnable? = null

    /** elapsedRealtime of the last fix we forwarded; 0 = none yet this run. */
    private var lastForwardedAt: Long = 0L

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        fused = LocationServices.getFusedLocationProviderClient(this)
        createNotificationChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP -> {
                persistEnabled(false)
                stopUpdates()
                stopSelf()
                return START_NOT_STICKY
            }
            ACTION_PAUSE -> {
                // Pause for 1h: stop updates but keep the (paused) notification.
                stopUpdates()
                notifText = "Paused — resumes in 1 hour"
                startForegroundCompat(buildNotification(paused = true))
                notifyBg("pause", mapOf("minutes" to 60))
                return START_STICKY
            }
            else -> {
                // START (from UI/boot). Read config, persist, run.
                intent?.let { readConfig(it) }
                startForegroundCompat(buildNotification(paused = false))
                ensureEngine()
                startUpdates()
                persistEnabled(true)
                return START_STICKY
            }
        }
    }

    private fun readConfig(intent: Intent) {
        val prefs = getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val interval = intent.getLongExtra(EXTRA_INTERVAL_MS, prefs.getLong(KEY_INTERVAL, 60_000))
        val disp = intent.getFloatExtra(EXTRA_DISPLACEMENT_M, prefs.getFloat(KEY_DISPLACEMENT, 20f))
        val prio = intent.getStringExtra(EXTRA_PRIORITY) ?: prefs.getString(KEY_PRIORITY, "balanced")!!
        notifText = intent.getStringExtra(EXTRA_NOTIF_TEXT) ?: prefs.getString(KEY_NOTIF, notifText)!!
        prefs.edit()
            .putLong(KEY_INTERVAL, interval)
            .putFloat(KEY_DISPLACEMENT, disp)
            .putString(KEY_PRIORITY, prio)
            .putString(KEY_NOTIF, notifText)
            .apply()
    }

    private fun persistEnabled(enabled: Boolean) {
        getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().putBoolean(KEY_ENABLED, enabled).apply()
    }

    // --- background Flutter isolate ---

    private fun ensureEngine() {
        if (engine != null) return
        val eng = FlutterEngine(applicationContext)
        val loader = FlutterInjector.instance().flutterLoader()
        loader.startInitialization(applicationContext)
        loader.ensureInitializationComplete(applicationContext, null)
        val entrypoint = DartExecutor.DartEntrypoint(
            loader.findAppBundlePath(),
            "aulLocationServiceMain",
        )
        eng.dartExecutor.executeDartEntrypoint(entrypoint)
        // Register plugins (secure storage, path_provider, etc.) on this engine.
        try {
            io.flutter.plugins.GeneratedPluginRegistrant.registerWith(eng)
        } catch (_: Throwable) {
            // Registrant may be a no-op if no method-channel plugins are present.
        }
        val channel = MethodChannel(eng.dartExecutor.binaryMessenger, BG_CHANNEL)
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "updateInterval" -> {
                    val interval = (call.argument<Number>("interval_ms"))?.toLong() ?: 60_000
                    val disp = (call.argument<Number>("displacement_m"))?.toFloat() ?: 20f
                    val prio = call.argument<String>("priority") ?: "balanced"
                    reconfigure(interval, disp, prio)
                    result.success(null)
                }
                "updateNotification" -> {
                    notifText = call.argument<String>("text") ?: notifText
                    startForegroundCompat(buildNotification(paused = false))
                    result.success(null)
                }
                "ready" -> result.success(mapOf("ok" to true))
                else -> result.notImplemented()
            }
        }
        bgChannel = channel
        engine = eng
    }

    private fun notifyBg(method: String, args: Any?) {
        bgChannel?.invokeMethod(method, args)
    }

    // --- location updates ---

    private fun currentInterval(): Long =
        getSharedPreferences(PREFS, Context.MODE_PRIVATE).getLong(KEY_INTERVAL, 60_000)

    /** The accuracy the stream is asking for. The periodic re-ask below MUST use
     *  this same value: a "kick" that quietly asks for a coarser fix than the
     *  stream would report a network estimate as if it were the real thing. */
    private fun currentPriority(): Int {
        val prefs = getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        return if (prefs.getString(KEY_PRIORITY, "balanced") == "high")
            Priority.PRIORITY_HIGH_ACCURACY else Priority.PRIORITY_BALANCED_POWER_ACCURACY
    }

    private fun currentRequest(): LocationRequest {
        val prefs = getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val interval = currentInterval()
        val disp = prefs.getFloat(KEY_DISPLACEMENT, 20f)
        return LocationRequest.Builder(currentPriority(), interval)
            .setMinUpdateIntervalMillis(maxOf(5_000, interval / 2))
            .setMinUpdateDistanceMeters(disp)
            .setWaitForAccurateLocation(false)
            .build()
    }

    private fun startUpdates() {
        stopUpdates()
        val cb = object : LocationCallback() {
            override fun onLocationResult(result: LocationResult) {
                result.lastLocation?.let { forward(it) }
            }
        }
        callback = cb
        try {
            fused.requestLocationUpdates(currentRequest(), cb, Looper.getMainLooper())
        } catch (se: SecurityException) {
            // Missing permission — the UI onboarding handles requesting it.
            return
        }
        scheduleRefresh()
    }

    // --- stationary refresh ---
    //
    // setMinUpdateDistanceMeters() is a MOVEMENT gate: FusedLocationProvider will
    // not deliver a second update until the device has physically moved that far.
    // A phone sitting on a table therefore produces exactly ONE fix — whatever the
    // provider happened to have at start, often a coarse network estimate — and
    // then goes silent for the rest of the session. Its marker freezes there and
    // can never refine itself, which is precisely "the map shows me where I am
    // not".
    //
    // So when the stream has said nothing for a whole interval, we RE-ASK the
    // provider for a current fix rather than re-sending the old one with a fresh
    // timestamp. A re-ask can come back sharper (the GPS has had time to settle);
    // a re-send could only ever repeat the same wrong place while claiming to be
    // news. The displacement filter stays — it is what keeps the battery budget —
    // but it no longer means silence.

    private fun scheduleRefresh() {
        cancelRefresh()
        val interval = currentInterval()
        val tick = object : Runnable {
            override fun run() {
                maybeRefresh(interval)
                handler.postDelayed(this, interval)
            }
        }
        refreshTick = tick
        handler.postDelayed(tick, interval)
    }

    private fun cancelRefresh() {
        refreshTick?.let { handler.removeCallbacks(it) }
        refreshTick = null
    }

    private fun maybeRefresh(interval: Long) {
        if (callback == null) return // not streaming; nothing to top up
        // The stream is delivering (the device is moving) — leave it alone.
        if (lastForwardedAt != 0L && SystemClock.elapsedRealtime() - lastForwardedAt < interval) return
        try {
            fused.getCurrentLocation(currentPriority(), CancellationTokenSource().token)
                .addOnSuccessListener { loc -> loc?.let { forward(it) } }
        } catch (se: SecurityException) {
            // Missing permission — the UI onboarding handles requesting it.
        }
    }

    private fun reconfigure(intervalMs: Long, displacementM: Float, priority: String) {
        getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
            .putLong(KEY_INTERVAL, intervalMs)
            .putFloat(KEY_DISPLACEMENT, displacementM)
            .putString(KEY_PRIORITY, priority)
            .apply()
        if (callback != null) startUpdates()
    }

    private fun stopUpdates() {
        cancelRefresh()
        callback?.let { fused.removeLocationUpdates(it) }
        callback = null
        lastForwardedAt = 0L
    }

    private fun forward(loc: Location) {
        lastForwardedAt = SystemClock.elapsedRealtime()
        val batt = try {
            val bm = getSystemService(android.os.BatteryManager::class.java)
            bm?.getIntProperty(android.os.BatteryManager.BATTERY_PROPERTY_CAPACITY)
        } catch (_: Throwable) {
            null
        }
        val payload = hashMapOf<String, Any?>(
            "lat" to loc.latitude,
            "lng" to loc.longitude,
            "acc" to if (loc.hasAccuracy()) loc.accuracy.toDouble() else null,
            "spd" to if (loc.hasSpeed()) loc.speed.toDouble() else null,
            "hdg" to if (loc.hasBearing()) loc.bearing.toDouble() else null,
            "batt" to if (batt != null && batt in 0..100) batt else null,
            "ts" to loc.time,
        )
        bgChannel?.invokeMethod("onLocation", payload)
    }

    // --- notification ---

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val ch = NotificationChannel(
                CHANNEL_ID, "Location sharing", NotificationManager.IMPORTANCE_LOW,
            ).apply {
                description = "Shown whenever Aul is sharing your location."
                setShowBadge(false)
            }
            getSystemService(NotificationManager::class.java).createNotificationChannel(ch)
        }
    }

    private fun buildNotification(paused: Boolean): Notification {
        val openApp = PendingIntent.getActivity(
            this, 0,
            packageManager.getLaunchIntentForPackage(packageName),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        val builder = NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("Aul")
            .setContentText(notifText)
            .setSmallIcon(android.R.drawable.ic_menu_mylocation)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setContentIntent(openApp)
            .setPriority(NotificationCompat.PRIORITY_LOW)

        if (!paused) {
            val pauseIntent = PendingIntent.getService(
                this, 1,
                Intent(this, LocationService::class.java).apply { action = ACTION_PAUSE },
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
            )
            builder.addAction(0, "Pause 1h", pauseIntent)
        }
        return builder.build()
    }

    private fun startForegroundCompat(notification: Notification) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(NOTIF_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_LOCATION)
        } else {
            startForeground(NOTIF_ID, notification)
        }
    }

    override fun onDestroy() {
        stopUpdates()
        engine?.destroy()
        engine = null
        super.onDestroy()
    }
}
