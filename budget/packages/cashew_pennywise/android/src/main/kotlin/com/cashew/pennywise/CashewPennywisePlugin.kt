package com.cashew.pennywise

import android.app.Activity
import android.content.Context
import android.os.Handler
import android.os.Looper
import androidx.annotation.NonNull
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result
import io.flutter.plugin.common.PluginRegistry.RequestPermissionsResultListener
import java.util.concurrent.Executors

/**
 * Android entry point. Exposes:
 *  - the vendored PennyWise SMS parser (ping/isKnownSender/parse/parseBatch),
 *  - the SMS capture pipeline: inbox reader, runtime permissions, and
 *    notification-access status, all over MethodChannel `cashew_pennywise/parser`,
 *  - a live incoming-SMS EventChannel `cashew_pennywise/sms_stream`.
 *
 * Runtime permission requests need an Activity, so the plugin is [ActivityAware].
 */
class CashewPennywisePlugin :
    FlutterPlugin,
    MethodCallHandler,
    ActivityAware,
    RequestPermissionsResultListener {

    private lateinit var channel: MethodChannel
    private lateinit var eventChannel: EventChannel
    private lateinit var notificationEventChannel: EventChannel
    private lateinit var appContext: Context

    // Parsing a full inbox / reading SMS can be thousands of messages; keep it off
    // the main thread. Reused for both parser and content-resolver work.
    private val worker = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())

    // ─── Activity + pending permission request state ──────────────────────────
    private var activityBinding: ActivityPluginBinding? = null
    private var activity: Activity? = null

    /** The Result for an in-flight requestSmsPermissions call (single-flight). */
    private var pendingPermissionResult: Result? = null

    override fun onAttachedToEngine(@NonNull binding: FlutterPlugin.FlutterPluginBinding) {
        appContext = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, CHANNEL)
        channel.setMethodCallHandler(this)
        eventChannel = EventChannel(binding.binaryMessenger, EVENT_CHANNEL)
        eventChannel.setStreamHandler(SmsLiveStreamHandler(appContext))
        notificationEventChannel =
            EventChannel(binding.binaryMessenger, NOTIFICATION_EVENT_CHANNEL)
        notificationEventChannel.setStreamHandler(NotificationStreamHandler())
    }

    override fun onDetachedFromEngine(@NonNull binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
        eventChannel.setStreamHandler(null)
        notificationEventChannel.setStreamHandler(null)
    }

    // ─── ActivityAware ────────────────────────────────────────────────────────

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activityBinding = binding
        activity = binding.activity
        binding.addRequestPermissionsResultListener(this)
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) =
        onAttachedToActivity(binding)

    override fun onDetachedFromActivityForConfigChanges() = detachActivity()

    override fun onDetachedFromActivity() = detachActivity()

    private fun detachActivity() {
        activityBinding?.removeRequestPermissionsResultListener(this)
        activityBinding = null
        activity = null
    }

    // ─── MethodChannel ────────────────────────────────────────────────────────

    override fun onMethodCall(@NonNull call: MethodCall, @NonNull result: Result) {
        when (call.method) {
            "ping" -> result.success(ParserBridge.parserCount())

            "isKnownSender" -> {
                val sender = call.argument<String>("sender")
                if (sender == null) { result.error("ARG", "sender required", null); return }
                result.success(ParserBridge.isKnownSender(sender))
            }

            "parse" -> runAsync(result) {
                val sender = call.argument<String>("sender") ?: return@runAsync null
                val body = call.argument<String>("body") ?: return@runAsync null
                val ts = (call.argument<Number>("timestamp"))?.toLong()
                    ?: System.currentTimeMillis()
                ParserBridge.parse(sender, body, ts)
            }

            "parseBatch" -> runAsync(result) {
                @Suppress("UNCHECKED_CAST")
                val messages = call.argument<List<Map<String, Any?>>>("messages") ?: emptyList()
                ParserBridge.parseBatch(messages)
            }

            "parseMandate" -> runAsync(result) {
                val sender = call.argument<String>("sender") ?: return@runAsync null
                val body = call.argument<String>("body") ?: return@runAsync null
                ParserBridge.parseMandate(sender, body)
            }

            // ─── Capture pipeline ─────────────────────────────────────────────

            "hasSmsPermissions" ->
                result.success(SmsPermissionHelper.hasSmsPermissions(appContext))

            "requestSmsPermissions" -> requestSmsPermissions(result)

            "readInbox" -> runAsync(result) {
                val since = (call.argument<Number>("sinceEpochMillis"))?.toLong()
                val before = (call.argument<Number>("beforeEpochMillis"))?.toLong()
                val limit = (call.argument<Number>("limit"))?.toInt()
                SmsInboxReader.read(appContext, since, before, limit)
            }

            "hasNotificationAccess" ->
                result.success(SmsPermissionHelper.hasNotificationAccess(appContext))

            "openNotificationAccessSettings" -> {
                try {
                    SmsPermissionHelper.openNotificationAccessSettings(activity ?: appContext)
                    result.success(true)
                } catch (e: Throwable) {
                    result.error("NO_SETTINGS", e.message, null)
                }
            }

            else -> result.notImplemented()
        }
    }

    // ─── Runtime permission request ───────────────────────────────────────────

    private fun requestSmsPermissions(result: Result) {
        // Already granted → short-circuit, no dialog.
        if (SmsPermissionHelper.hasSmsPermissions(appContext)) {
            result.success(true)
            return
        }
        val act = activity
        if (act == null) {
            result.error("NO_ACTIVITY", "No Activity attached to request permissions", null)
            return
        }
        if (pendingPermissionResult != null) {
            result.error("ALREADY_PENDING", "A permission request is already in flight", null)
            return
        }
        pendingPermissionResult = result
        SmsPermissionHelper.requestSmsPermissions(act)
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ): Boolean {
        if (requestCode != SmsPermissionHelper.REQUEST_CODE_SMS) return false
        val result = pendingPermissionResult
        pendingPermissionResult = null
        // Re-query the real state rather than trusting grantResults ordering — also
        // covers the "user granted in a prior dialog" race.
        result?.success(SmsPermissionHelper.hasSmsPermissions(appContext))
        return true
    }

    // ─── Async helper ─────────────────────────────────────────────────────────

    /** Runs [block] on the worker thread and posts the result back on the main thread. */
    private fun runAsync(result: Result, block: () -> Any?) {
        worker.execute {
            try {
                val value = block()
                main.post { result.success(value) }
            } catch (e: Throwable) {
                main.post { result.error("PARSE_ERROR", e.message, null) }
            }
        }
    }

    companion object {
        private const val CHANNEL = "cashew_pennywise/parser"
        private const val EVENT_CHANNEL = "cashew_pennywise/sms_stream"
        private const val NOTIFICATION_EVENT_CHANNEL =
            "cashew_pennywise/notification_stream"
    }
}
