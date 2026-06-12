package com.cashew.pennywise

import android.content.Context
import android.provider.Telephony

/**
 * Reads the device SMS inbox via [Telephony.Sms.CONTENT_URI]. Ported from
 * PennyWise's `OptimizedSmsReaderWorker` cursor reader, but trimmed to a
 * pageable, side-effect-free reader: the Dart [SmsScanner] owns the pipeline
 * orchestration (parse / dedup / progress), so this is purely a feed.
 *
 * Pagination contract (consumed by the Dart `SmsInbox`):
 *  - [sinceEpochMillis]  : lower bound (inclusive) on DATE. null/0 = all time.
 *  - [sinceIdExclusive]  : tie-breaker for rows with DATE == sinceEpochMillis.
 *  - [beforeEpochMillis] : upper bound (exclusive) on DATE. null = no upper bound.
 *  - [limit]             : max rows to return. null = unbounded.
 *
 * Rows are returned ordered by DATE ASC, _ID ASC so the Dart side can page
 * forward without dropping same-millisecond rows at a page boundary.
 */
internal object SmsInboxReader {

    private val PROJECTION = arrayOf(
        Telephony.Sms._ID,
        Telephony.Sms.ADDRESS,
        Telephony.Sms.DATE,
        Telephony.Sms.BODY,
    )

    /**
     * @return list of `{id, sender, body, timestamp}` maps (codec-safe
     *         primitives), ordered by timestamp ascending.
     */
    fun read(
        context: Context,
        sinceEpochMillis: Long?,
        sinceIdExclusive: Long?,
        beforeEpochMillis: Long?,
        limit: Int?,
    ): List<Map<String, Any?>> {
        val selectionParts = mutableListOf("${Telephony.Sms.TYPE} = ?")
        val args = mutableListOf(Telephony.Sms.MESSAGE_TYPE_INBOX.toString())

        if (sinceEpochMillis != null && sinceEpochMillis > 0L) {
            if (sinceIdExclusive != null) {
                selectionParts += "(${Telephony.Sms.DATE} > ? OR (${Telephony.Sms.DATE} = ? AND ${Telephony.Sms._ID} > ?))"
                args += sinceEpochMillis.toString()
                args += sinceEpochMillis.toString()
                args += sinceIdExclusive.toString()
            } else {
                selectionParts += "${Telephony.Sms.DATE} >= ?"
                args += sinceEpochMillis.toString()
            }
        }
        if (beforeEpochMillis != null) {
            selectionParts += "${Telephony.Sms.DATE} < ?"
            args += beforeEpochMillis.toString()
        }

        val selection = selectionParts.joinToString(" AND ")
        // LIMIT is appended to the sort order — supported by the SMS provider's
        // SQLite-backed query path. Harmless if ignored by an odd OEM provider.
        val sortOrder = buildString {
            append("${Telephony.Sms.DATE} ASC, ${Telephony.Sms._ID} ASC")
            if (limit != null && limit > 0) append(" LIMIT ").append(limit)
        }

        val out = ArrayList<Map<String, Any?>>(limit?.coerceAtMost(1024) ?: 256)
        context.contentResolver.query(
            Telephony.Sms.CONTENT_URI,
            PROJECTION,
            selection,
            args.toTypedArray(),
            sortOrder,
        )?.use { c ->
            val addressIdx = c.getColumnIndexOrThrow(Telephony.Sms.ADDRESS)
            val idIdx = c.getColumnIndexOrThrow(Telephony.Sms._ID)
            val dateIdx = c.getColumnIndexOrThrow(Telephony.Sms.DATE)
            val bodyIdx = c.getColumnIndexOrThrow(Telephony.Sms.BODY)
            var emitted = 0
            while (c.moveToNext()) {
                if (limit != null && emitted >= limit) break
                out += mapOf(
                    "id" to c.getLong(idIdx),
                    "sender" to (c.getString(addressIdx) ?: ""),
                    "body" to (c.getString(bodyIdx) ?: ""),
                    "timestamp" to c.getLong(dateIdx),
                )
                emitted++
            }
        }
        return out
    }
}
