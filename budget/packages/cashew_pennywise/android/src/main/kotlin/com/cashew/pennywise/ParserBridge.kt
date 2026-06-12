package com.cashew.pennywise

import com.pennywiseai.parser.core.MandateInfo
import com.pennywiseai.parser.core.ParsedTransaction
import com.pennywiseai.parser.core.bank.BankParserFactory
import com.pennywiseai.parser.core.bank.BaseIndianBankParser
import com.pennywiseai.parser.core.bank.FederalBankParser
import com.pennywiseai.parser.core.bank.HDFCBankParser
import com.pennywiseai.parser.core.bank.PNBBankParser
import com.pennywiseai.parser.core.bank.SBIBankParser
import java.text.SimpleDateFormat
import java.util.Locale

/**
 * Thin adapter between the vendored PennyWise [BankParserFactory] and the
 * MethodChannel codec. Serializes [ParsedTransaction] to a map of codec-safe
 * primitives (BigDecimal -> plain String to preserve precision).
 */
internal object ParserBridge {

    fun parse(sender: String, body: String, timestamp: Long): Map<String, Any?>? =
        BankParserFactory.parse(body, sender, timestamp)?.toMap()

    /**
     * E-mandate / subscription detection. The regular [parse] path returns null
     * for a mandate-setup SMS (no debit), so this is a separate entry point.
     * Tries the bank-specific mandate parsers first, then the generic base.
     */
    fun parseMandate(sender: String, body: String): Map<String, Any?>? {
        val parser = BankParserFactory.getParser(sender) ?: return null
        val mandate: MandateInfo? = when (parser) {
            is HDFCBankParser ->
                parser.parseEMandateSubscription(body) ?: parser.parseFutureDebit(body)
            is FederalBankParser ->
                parser.parseEMandateSubscription(body) ?: parser.parseFutureDebit(body)
            is SBIBankParser -> parser.parseUPIMandateSubscription(body)
            is PNBBankParser -> parser.parseUPIMandateSubscription(body)
            else -> null
        } ?: (parser as? BaseIndianBankParser)?.parseMandateSubscription(body)

        return mandate?.toMap(parser.getBankName(), sender, body)
    }

    private fun MandateInfo.toMap(
        bankName: String,
        sender: String,
        smsBody: String,
    ): Map<String, Any?> = mapOf(
        "amount" to amount.toPlainString(),
        "merchant" to merchant,
        "umn" to umn,
        "nextDeductionDate" to nextDeductionDate,
        "nextDeductionEpochMillis" to parseMandateDate(nextDeductionDate, dateFormat),
        "bankName" to bankName,
        "sender" to sender,
        "smsBody" to smsBody,
    )

    /** Parse a bank-format date string to epoch millis, trying common formats. */
    private fun parseMandateDate(raw: String?, preferredFormat: String): Long? {
        if (raw == null) return null
        val formats = listOf(
            preferredFormat, "dd-MMM-yy", "dd/MM/yy", "dd/MM/yyyy", "d-MMM-yy", "dd-MM-yyyy",
        )
        for (fmt in formats) {
            try {
                return SimpleDateFormat(fmt, Locale.ENGLISH).parse(raw)?.time
            } catch (_: Exception) {
            }
        }
        return null
    }

    /** Parse many messages at once. Unparseable entries are dropped. */
    fun parseBatch(messages: List<Map<String, Any?>>): List<Map<String, Any?>> =
        messages.mapNotNull { msg ->
            val sender = msg["sender"] as? String ?: return@mapNotNull null
            val body = msg["body"] as? String ?: return@mapNotNull null
            val ts = (msg["timestamp"] as? Number)?.toLong() ?: return@mapNotNull null
            BankParserFactory.parse(body, sender, ts)?.toMap()
        }

    fun isKnownSender(sender: String): Boolean = BankParserFactory.isKnownBankSender(sender)

    fun parserCount(): Int = BankParserFactory.getAllParsers().size

    private fun ParsedTransaction.toMap(): Map<String, Any?> = mapOf(
        "amount" to amount.toPlainString(),
        "type" to type.name,
        "merchant" to merchant,
        "reference" to reference,
        "accountLast4" to accountLast4,
        "balance" to balance?.toPlainString(),
        "creditLimit" to creditLimit?.toPlainString(),
        "smsBody" to smsBody,
        "sender" to sender,
        "timestamp" to timestamp,
        "bankName" to bankName,
        "transactionId" to generateTransactionId(),
        "isFromCard" to isFromCard,
        "currency" to currency,
        "fromAccount" to fromAccount,
        "toAccount" to toAccount,
    )
}
