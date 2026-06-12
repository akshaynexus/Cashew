package com.cashew.pennywise

import android.os.Handler
import android.os.Looper
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification
import io.flutter.plugin.common.EventChannel
import java.util.concurrent.atomic.AtomicReference

/**
 * Listens for posted notifications from allowlisted bank apps and forwards
 * `{packageName, title, text, postTime}` to Dart over the
 * `cashew_pennywise/notification_stream` EventChannel.
 *
 * A [NotificationListenerService] is instantiated by the Android system, not by
 * the Flutter plugin, so it cannot hold a plugin field. The bridge is a static
 * [sink]: the plugin's [NotificationStreamHandler] publishes the active
 * [EventChannel.EventSink] here while a Dart listener is attached, and this
 * service reads it. Events are always delivered on the main thread (the sink is
 * not thread-safe).
 *
 * Ported from PennyWise's `BankNotificationListenerService`, minus the Hilt /
 * repository plumbing — parsing happens entirely on the Dart side.
 */
class BankNotificationListenerService : NotificationListenerService() {

    override fun onNotificationPosted(sbn: StatusBarNotification) {
        val sink = sink.get() ?: return // No Dart listener attached → ignore.

        val packageName = sbn.packageName ?: return
        if (!NotificationConfig.isAllowed(packageName)) return

        // Skip group summaries: their child notifications carry the real text and
        // forwarding both would double-process the same payment.
        val notification = sbn.notification ?: return
        if ((notification.flags and android.app.Notification.FLAG_GROUP_SUMMARY) != 0) return

        val text = NotificationConfig.extractText(notification)
        val title = NotificationConfig.extractTitle(notification)
        if (text.isBlank() && title.isBlank()) return

        val event = mapOf(
            "packageName" to packageName,
            "title" to title,
            "text" to text,
            "postTime" to sbn.postTime,
        )
        main.post {
            try {
                sink.success(event)
            } catch (_: Throwable) {
                // Sink may have been cancelled between dispatch and post.
            }
        }
    }

    companion object {
        private val main = Handler(Looper.getMainLooper())

        /** Active Dart event sink, published by [NotificationStreamHandler]. */
        private val sink = AtomicReference<EventChannel.EventSink?>(null)

        fun attachSink(eventSink: EventChannel.EventSink?) = sink.set(eventSink)

        fun detachSink(eventSink: EventChannel.EventSink?) {
            sink.compareAndSet(eventSink, null)
        }
    }
}

/**
 * StreamHandler that plugs a Dart listener into [BankNotificationListenerService].
 * The service itself keeps running whenever notification access is granted; this
 * only governs whether forwarded events reach Dart.
 */
internal class NotificationStreamHandler : EventChannel.StreamHandler {
    private var active: EventChannel.EventSink? = null

    override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
        active = events
        BankNotificationListenerService.attachSink(events)
    }

    override fun onCancel(arguments: Any?) {
        BankNotificationListenerService.detachSink(active)
        active = null
    }
}
