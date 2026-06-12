package com.cashew.pennywise

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/**
 * Manifest-declared `SMS_RECEIVED` receiver.
 *
 * Live delivery to Dart while the app is running is handled by the
 * dynamically-registered receiver in [SmsLiveStreamHandler] (active only while a
 * Dart listener is attached to the `cashew_pennywise/sms_stream` EventChannel).
 *
 * This static receiver exists so the capability is declared in the manifest and
 * the app can be considered for the BROADCAST_SMS-gated delivery. Background
 * processing (waking the Flutter engine when no listener is attached) is a later
 * build step (notification listener / background isolate), so for now this is a
 * deliberate no-op — it must never crash the broadcast.
 */
class SmsReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        // Intentionally empty. See class KDoc. The dynamic receiver owns live
        // delivery; background wakeup is out of scope for this step.
    }
}
