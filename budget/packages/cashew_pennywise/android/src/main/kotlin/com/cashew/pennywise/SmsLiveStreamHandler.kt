package com.cashew.pennywise

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Telephony
import io.flutter.plugin.common.EventChannel

/**
 * Live incoming-SMS stream over an EventChannel. Registers a [BroadcastReceiver]
 * for `SMS_RECEIVED_ACTION` only while a Dart listener is attached, and tears it
 * down when the stream is cancelled — so we never hold a receiver with no
 * consumer.
 *
 * Multi-part reassembly is ported from PennyWise's `SmsBroadcastReceiver`:
 * the PDUs in one broadcast are grouped by originating address, bodies
 * concatenated in arrival order, and the EARLIEST part timestamp is used.
 *
 * Events are `{sender, body, timestamp}` maps, delivered on the main thread
 * (EventChannel.EventSink is not thread-safe).
 */
internal class SmsLiveStreamHandler(
    private val context: Context,
) : EventChannel.StreamHandler {

    private val main = Handler(Looper.getMainLooper())
    private var receiver: BroadcastReceiver? = null

    override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
        // Defensive: drop any stale receiver before registering a new one.
        unregister()

        val r = object : BroadcastReceiver() {
            override fun onReceive(ctx: Context, intent: Intent) {
                if (intent.action != Telephony.Sms.Intents.SMS_RECEIVED_ACTION) return
                val messages = try {
                    Telephony.Sms.Intents.getMessagesFromIntent(intent)
                } catch (_: Throwable) {
                    null
                } ?: return
                if (messages.isEmpty()) return

                // sender -> (concatenated body, earliest timestamp)
                val bySender = LinkedHashMap<String, Pair<StringBuilder, Long>>()
                for (m in messages) {
                    val sender = m.originatingAddress ?: continue
                    val body = m.messageBody ?: continue
                    val ts = m.timestampMillis
                    val existing = bySender[sender]
                    if (existing == null) {
                        bySender[sender] = StringBuilder(body) to ts
                    } else {
                        existing.first.append(body)
                        if (ts < existing.second) {
                            bySender[sender] = existing.first to ts
                        }
                    }
                }

                for ((sender, data) in bySender) {
                    val event = mapOf(
                        "sender" to sender,
                        "body" to data.first.toString(),
                        "timestamp" to data.second,
                    )
                    main.post {
                        try {
                            events.success(event)
                        } catch (_: Throwable) {
                            // Sink may have been cancelled between dispatch and post.
                        }
                    }
                }
            }
        }
        receiver = r

        val filter = IntentFilter(Telephony.Sms.Intents.SMS_RECEIVED_ACTION).apply {
            priority = 999
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            context.registerReceiver(r, filter, Context.RECEIVER_EXPORTED)
        } else {
            @Suppress("UnspecifiedRegisterReceiverFlag")
            context.registerReceiver(r, filter)
        }
    }

    override fun onCancel(arguments: Any?) {
        unregister()
    }

    private fun unregister() {
        receiver?.let {
            try {
                context.unregisterReceiver(it)
            } catch (_: IllegalArgumentException) {
                // Not registered; ignore.
            }
        }
        receiver = null
    }
}
