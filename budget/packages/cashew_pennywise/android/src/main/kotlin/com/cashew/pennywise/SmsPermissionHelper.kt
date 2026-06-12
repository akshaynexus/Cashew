package com.cashew.pennywise

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.provider.Settings
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat

/**
 * Runtime permission + notification-access helpers. Ported from PennyWise's
 * `PermissionViewModel`/`PermissionScreen`: the runtime permissions we need are
 * READ_SMS, RECEIVE_SMS, and (on API 33+) POST_NOTIFICATIONS. Notification
 * listener access is granted via a system Settings deep-link, not a runtime
 * permission, and read back via [NotificationManagerCompat.getEnabledListenerPackages].
 */
internal object SmsPermissionHelper {

    /** Request code for the runtime SMS/notification permission dialog. */
    const val REQUEST_CODE_SMS = 0x5A11 // arbitrary, distinct

    /** Permissions we request at runtime. POST_NOTIFICATIONS only on API 33+. */
    fun requiredPermissions(): Array<String> {
        val base = mutableListOf(
            Manifest.permission.READ_SMS,
            Manifest.permission.RECEIVE_SMS,
        )
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            base += Manifest.permission.POST_NOTIFICATIONS
        }
        return base.toTypedArray()
    }

    private fun isGranted(context: Context, permission: String): Boolean =
        ContextCompat.checkSelfPermission(context, permission) ==
            PackageManager.PERMISSION_GRANTED

    /** True only if BOTH READ_SMS and RECEIVE_SMS are granted (capture-critical). */
    fun hasSmsPermissions(context: Context): Boolean =
        isGranted(context, Manifest.permission.READ_SMS) &&
            isGranted(context, Manifest.permission.RECEIVE_SMS)

    /** Whether this app is an enabled notification listener. */
    fun hasNotificationAccess(context: Context): Boolean =
        NotificationManagerCompat.getEnabledListenerPackages(context)
            .contains(context.packageName)

    /** Launch the system notification-listener settings screen. */
    fun openNotificationAccessSettings(context: Context) {
        val intent = Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS)
        // May be launched from a non-Activity context (the plugin only holds the
        // application context when no Activity is attached).
        if (context !is Activity) intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        context.startActivity(intent)
    }

    /** Kicks off the runtime permission request on [activity]. */
    fun requestSmsPermissions(activity: Activity) {
        activity.requestPermissions(requiredPermissions(), REQUEST_CODE_SMS)
    }
}
