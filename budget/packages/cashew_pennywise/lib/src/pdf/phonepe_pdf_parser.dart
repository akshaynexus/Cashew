import 'dart:convert';

import '../parsed_transaction.dart';
import 'pdf_statement_parser.dart';

/// Parses PhonePe PDF statement exports into [ParsedTransaction] objects.
///
/// Ported from PennyWise's `PhonePePdfParser.kt`. Blocks are split on
/// DEBIT/CREDIT or "Paid to" / "Sent to" / "Transferred to" / "Received from"
/// markers; the type is taken from the first line of each block.
class PhonePePdfParser implements PdfStatementParser {
  static const List<String> _phonePeKeywords = ['phonepe', 'phone pe'];

  static final RegExp _amountPattern =
      RegExp(r'[₹Rs.]+\s*([\d,]+(?:\.\d{1,2})?)');
  static final RegExp _txnIdPattern = RegExp(
      r'(?:Transaction\s+ID|UTR(?:\s+No)?)[:\s]*([A-Za-z0-9]+)',
      caseSensitive: false);
  // Matches "01 Sep, 2025" / "01 Sep 2025" / "Sep 01, 2025" / "Sep 01 2025".
  static final RegExp _datePattern = RegExp(
      r'(\d{1,2}\s+\w{3}[,]?\s+\d{4}|\w{3}\s+\d{1,2}[,]?\s+\d{4})');
  static final RegExp _merchantPattern = RegExp(
      r'(?:Paid\s+to|Sent\s+to|Transferred\s+to|Received\s+from)\s+(.+?)(?:\n|$)',
      caseSensitive: false);

  static final RegExp _amountLeadingPattern = RegExp(r'^[₹Rs.\d,]+.*');

  @override
  bool canHandle(String text) {
    final lower = text.toLowerCase();
    return _phonePeKeywords.any((k) => lower.contains(k));
  }

  @override
  List<ParsedTransaction> parse(String text) {
    final transactions = <ParsedTransaction>[];
    for (final block in _splitIntoTransactionBlocks(text)) {
      final tx = _parseBlock(block);
      if (tx != null) transactions.add(tx);
    }
    return transactions;
  }

  List<String> _splitIntoTransactionBlocks(String text) {
    final blocks = <String>[];
    final lines = const LineSplitter().convert(text);
    var currentBlock = StringBuffer();
    var inTransaction = false;

    for (final line in lines) {
      final trimmed = line.trim();
      final lower = trimmed.toLowerCase();
      final isDebit = lower == 'debit' || lower.startsWith('debit ');
      final isCredit = lower == 'credit' || lower.startsWith('credit ');
      final isPaidTo = lower.startsWith('paid to') ||
          lower.startsWith('sent to') ||
          lower.startsWith('transferred to');
      final isReceivedFrom = lower.startsWith('received from');

      if (isDebit || isCredit || isPaidTo || isReceivedFrom) {
        if (inTransaction && currentBlock.isNotEmpty) {
          blocks.add(currentBlock.toString());
          currentBlock = StringBuffer();
        }
        inTransaction = true;
      }

      if (inTransaction) currentBlock.writeln(line);
    }

    if (currentBlock.isNotEmpty) blocks.add(currentBlock.toString());
    return blocks;
  }

  ParsedTransaction? _parseBlock(String block) {
    final amount = _extractAmount(block);
    if (amount == null) return null;
    final type = _extractTransactionType(block);
    if (type == null) return null;
    final merchant = _extractMerchant(block);
    final reference = _extractTransactionId(block);
    final timestamp = _extractTimestamp(block) ?? DateTime.now();

    final trimmed = block.trim();
    return ParsedTransaction(
      amount: amount,
      type: type,
      merchant: merchant?.trim(),
      reference: reference,
      accountLast4: null,
      balance: null,
      creditLimit: null,
      sourceText: trimmed,
      sender: 'PhonePe PDF',
      timestamp: timestamp,
      bankName: 'PhonePe',
      transactionId: stableTransactionId(
          'PhonePe PDF|$amount|${reference ?? ''}|${timestamp.millisecondsSinceEpoch}'),
      isFromCard: false,
      currency: 'INR',
      fromAccount: null,
      toAccount: null,
    );
  }

  /// Returns the amount as a normalized numeric string (commas stripped).
  String? _extractAmount(String block) {
    final m = _amountPattern.firstMatch(block);
    if (m == null) return null;
    final cleaned = m.group(1)!.replaceAll(',', '');
    return double.tryParse(cleaned) != null ? cleaned : null;
  }

  ParsedTransactionType? _extractTransactionType(String block) {
    final firstLine = const LineSplitter()
        .convert(block)
        .map((l) => l.trim())
        .firstWhere((l) => true, orElse: () => '')
        .toUpperCase();
    if (firstLine.isEmpty && block.trim().isEmpty) return null;

    if (firstLine.startsWith('DEBIT')) return ParsedTransactionType.expense;
    if (firstLine.startsWith('CREDIT')) return ParsedTransactionType.income;
    if (firstLine.startsWith('PAID TO') ||
        firstLine.startsWith('SENT TO') ||
        firstLine.startsWith('TRANSFERRED TO')) {
      return ParsedTransactionType.expense;
    }
    if (firstLine.startsWith('RECEIVED FROM')) {
      return ParsedTransactionType.income;
    }
    final lowerBlock = block.toLowerCase();
    if (lowerBlock.contains('debit')) return ParsedTransactionType.expense;
    if (lowerBlock.contains('credit')) return ParsedTransactionType.income;
    return null;
  }

  String? _extractMerchant(String block) {
    final m = _merchantPattern.firstMatch(block);
    if (m != null) return m.group(1)!.trim();

    final lines = const LineSplitter()
        .convert(block)
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .toList();
    if (lines.length >= 2) {
      final secondLine = lines[1];
      if (!_amountLeadingPattern.hasMatch(secondLine) &&
          !secondLine.toLowerCase().startsWith('transaction') &&
          !secondLine.toLowerCase().startsWith('utr')) {
        return secondLine;
      }
    }
    return null;
  }

  String? _extractTransactionId(String block) =>
      _txnIdPattern.firstMatch(block)?.group(1);

  /// Parses a date like "01 Sep, 2025" / "Sep 01, 2025" in IST (date only).
  DateTime? _extractTimestamp(String block) {
    final m = _datePattern.firstMatch(block);
    if (m == null) return null;
    final dateStr = m.group(1)!.trim();

    // Try "dd MMM[,] yyyy".
    final dmy =
        RegExp(r'^(\d{1,2})\s+(\w{3})[,]?\s+(\d{4})$').firstMatch(dateStr);
    if (dmy != null) {
      final day = int.parse(dmy.group(1)!);
      final month = kMonthAbbreviations[dmy.group(2)!.toLowerCase()];
      final year = int.parse(dmy.group(3)!);
      if (month != null) return istDateTime(year, month, day);
    }
    // Try "MMM dd[,] yyyy".
    final mdy =
        RegExp(r'^(\w{3})\s+(\d{1,2})[,]?\s+(\d{4})$').firstMatch(dateStr);
    if (mdy != null) {
      final month = kMonthAbbreviations[mdy.group(1)!.toLowerCase()];
      final day = int.parse(mdy.group(2)!);
      final year = int.parse(mdy.group(3)!);
      if (month != null) return istDateTime(year, month, day);
    }
    return null;
  }
}
