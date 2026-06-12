package com.cashew.pennywise

import android.app.Notification
import android.os.Bundle

/**
 * Allowlist + message extraction for bank-app notifications. Ported from
 * PennyWise's `BankNotificationConfig`: only notifications whose package is in
 * [allowedPackages] are forwarded, and each maps to a sender alias the parser
 * recognises (must match the corresponding parser's `canHandle`).
 *
 * Privacy: notifications from non-bank apps are never read past their package
 * name.
 */
internal object NotificationConfig {

    /** package name -> sender alias fed to the parser. Keys are lowercase. */
    private val allowedPackages: Map<String, String> = mapOf(
        // Faysal Bank (Pakistan)
        "com.avanza.ambitwizfbl" to "FaysalBank",
        // Enpara (Turkey)
        "finansbank.enpara" to "Enpara",
        "com.enparabank.retail" to "Enpara",
    )

    fun isAllowed(packageName: String): Boolean =
        allowedPackages.containsKey(packageName.lowercase())

    fun senderAlias(packageName: String): String =
        allowedPackages[packageName.lowercase()] ?: packageName

    /**
     * Extracts the readable body from a notification's extras, preferring the
     * expanded "big text" then the collapsed text, falling back to the title.
     */
    fun extractText(notification: Notification): String {
        val extras: Bundle = notification.extras ?: return ""

        val parts = buildList {
            extras.getCharSequence(Notification.EXTRA_BIG_TEXT)?.let { add(it) }
            extras.getCharSequenceArray(Notification.EXTRA_TEXT_LINES)?.forEach { add(it) }
            extras.getCharSequence(Notification.EXTRA_TEXT)?.let { add(it) }
            extras.getCharSequence(Notification.EXTRA_SUMMARY_TEXT)?.let { add(it) }
        }
        if (parts.isNotEmpty()) {
            val merged = parts.joinToString("\n") { it.toString() }.trim()
            if (merged.isNotBlank()) return merged
        }
        return extras.getCharSequence(Notification.EXTRA_TITLE)?.toString()?.trim().orEmpty()
    }

    fun extractTitle(notification: Notification): String =
        notification.extras
            ?.getCharSequence(Notification.EXTRA_TITLE)
            ?.toString()
            ?.trim()
            .orEmpty()
}
