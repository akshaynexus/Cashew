import 'dart:convert';

import '../parsed_transaction.dart';
import 'pdf_statement_parser.dart';

/// Parses Google Pay PDF statement exports into [ParsedTransaction] objects.
///
/// Ported from PennyWise's `GPayPdfParser.kt` (Android version — the more
/// complete one with the table-layout + pending-date-buffer handling).
///
/// For income transactions the anchor is "Received from ..." and the account
/// line reads "Paid to South Indian Bank 1234" — which is NOT a new
/// transaction. We distinguish transaction anchors from account lines by
/// checking that a "Paid to" line does NOT match the bank-account pattern.
class GPayPdfParser implements PdfStatementParser {
  // ─── Patterns ─────────────────────────────────────────────────────────────

  // Matches "Paid to <merchant>" — but NOT "Paid to South Indian Bank 1234".
  static final RegExp _merchantAnchorRegex =
      RegExp(r'^Paid\s+to\s+(.+)$', caseSensitive: false);
  static final RegExp _receivedAnchorRegex =
      RegExp(r'^Received\s+from\s+(.+)$', caseSensitive: false);
  // Only matches if the name before the 4 digits contains a known account
  // keyword (Bank, Card, A/c). Prevents "Paid to Store 2024" from being
  // misclassified as an account line.
  static final RegExp _bankAccountLineRegex = RegExp(
      r'^Paid\s+(?:by|to)\s+(.+)\s+(Bank|Card|A/c)\s+(\d{4})$',
      caseSensitive: false);
  static final RegExp _upiIdRegex =
      RegExp(r'UPI\s+Transaction\s+ID[:\s]+(\d+)', caseSensitive: false);
  // Amount on its own line — currency prefix (₹, Rs.) required.
  static final RegExp _amountRegex =
      RegExp(r'^(?:₹|Rs\.?)\s*([0-9][0-9,]*(?:\.[0-9]{1,2})?)$');

  // Date parts — each on its own line.
  static final RegExp _dateLineRegex = RegExp(r'^(\d{1,2})\s+(\w{3}),?$');
  static final RegExp _fullDateLineRegex =
      RegExp(r'^(\d{1,2}\s+\w{3},\s+20\d{2})$');
  static final RegExp _datePrefixedRowRegex =
      RegExp(r'^(\d{1,2}\s+\w{3},\s+20\d{2})\s+(.+)$');
  static final RegExp _yearLineRegex = RegExp(r'^(20\d{2})$');
  static final RegExp _timeLineRegex =
      RegExp(r'^(\d{1,2}:\d{2})\s*([AaPp][Mm])(?:\s+(.+))?$');

  // Inline amount at end of a row (table layout).
  static final RegExp _trailingAmountRegex =
      RegExp(r'\s+((?:₹|Rs\.?)\s*[0-9][0-9,]*(?:\.[0-9]{1,2})?)$');

  // ─── Public API ─────────────────────────────────────────────────────────

  @override
  bool canHandle(String text) {
    final lower = text.toLowerCase();
    return (lower.contains('google pay') || lower.contains('gpay')) &&
        lower.contains('upi transaction id');
  }

  @override
  List<ParsedTransaction> parse(String text) {
    final blocks = _splitIntoBlocks(text);
    final transactions = <ParsedTransaction>[];
    for (final block in blocks) {
      final tx = _parseBlock(block);
      if (tx != null) transactions.add(tx);
    }
    return transactions;
  }

  // ─── Block splitting ──────────────────────────────────────────────────────

  /// Splits raw PDF text into one string per transaction.
  ///
  /// Date lines ("01 Sep,", "2025", "03:02 PM") appear on the lines BEFORE the
  /// transaction anchor in GPay exports. We keep a rolling "pending" triplet of
  /// the most-recent date/year/time lines, and each time a new anchor arrives
  /// we prepend that triplet to the new block. Date-pattern lines are never
  /// appended to the *current* block because they belong to the *next*
  /// transaction.
  List<String> _splitIntoBlocks(String text) {
    final blocks = <String>[];
    final current = StringBuffer();
    String? pendingDate;
    String? pendingYear;
    String? pendingTime;
    var inBlock = false;

    for (final rawLine in const LineSplitter().convert(text)) {
      final line = rawLine.trim();
      if (line.isEmpty) continue;

      final isDate = _dateLineRegex.hasMatch(line);
      final isFullDate = _fullDateLineRegex.hasMatch(line);
      final isYear = _yearLineRegex.hasMatch(line);
      final isTime = _timeLineRegex.hasMatch(line);

      final datePrefixedRow = _datePrefixedRowRegex.firstMatch(line);
      if (datePrefixedRow != null) {
        final fullDate = datePrefixedRow.group(1)!;
        final rest = datePrefixedRow.group(2)!.trim();
        final rowParts = _splitAnchorAndAmount(rest);
        if (_isTransactionAnchor(rowParts.anchorLine)) {
          if (inBlock && current.isNotEmpty) {
            blocks.add(current.toString().trim());
            current.clear();
          }
          current.writeln(fullDate);
          current.writeln(rowParts.anchorLine);
          if (rowParts.amountLine != null) current.writeln(rowParts.amountLine);
          pendingDate = null;
          pendingYear = null;
          pendingTime = null;
          inBlock = true;
          continue;
        }
      }

      if (_isTransactionAnchor(line)) {
        if (inBlock && current.isNotEmpty) {
          blocks.add(current.toString().trim());
          current.clear();
        }
        // Prepend the most-recent pending date triplet so this block owns its
        // own dates — then clear pending so the next transaction starts fresh.
        if (pendingDate != null) current.writeln(pendingDate);
        if (pendingYear != null) current.writeln(pendingYear);
        if (pendingTime != null) current.writeln(pendingTime);
        pendingDate = null;
        pendingYear = null;
        pendingTime = null;
        current.writeln(line);
        inBlock = true;
        continue;
      }

      // Date-pattern lines are NEVER appended to the current block — they
      // always belong to the next anchor's transaction.
      if (isDate) {
        pendingDate = line;
        continue;
      }
      if (isFullDate) {
        pendingDate = line;
        pendingYear = null;
        continue;
      }
      if (isYear) {
        pendingYear = line;
        continue;
      }
      // A time line with trailing content (group 3) belongs inline to the
      // current block; a bare time line is buffered for the next anchor.
      if (isTime && inBlock) {
        final m = _timeLineRegex.firstMatch(line);
        final trailing = m?.group(3);
        if (trailing != null && trailing.trim().isNotEmpty) {
          current.writeln(line);
          continue;
        }
      }
      if (isTime) {
        pendingTime = line;
        continue;
      }

      if (inBlock) current.writeln(line);
    }

    if (current.isNotEmpty) blocks.add(current.toString().trim());
    return blocks;
  }

  /// Returns true only for genuine transaction anchors. Account lines like
  /// "Paid to South Indian Bank 1234" are excluded.
  bool _isTransactionAnchor(String line) {
    if (_receivedAnchorRegex.hasMatch(line)) return true;
    if (_merchantAnchorRegex.hasMatch(line)) {
      return !_bankAccountLineRegex.hasMatch(line);
    }
    return false;
  }

  // ─── Block parsing ──────────────────────────────────────────────────────

  ParsedTransaction? _parseBlock(String block) {
    final lines = const LineSplitter()
        .convert(block)
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .toList();

    // Find the anchor line (may not be first due to prepended date lines).
    String? anchorLine;
    for (final l in lines) {
      if (_isTransactionAnchor(l)) {
        anchorLine = l;
        break;
      }
    }
    if (anchorLine == null) return null;

    final isExpense = _merchantAnchorRegex.hasMatch(anchorLine) &&
        !_bankAccountLineRegex.hasMatch(anchorLine);
    final type =
        isExpense ? ParsedTransactionType.expense : ParsedTransactionType.income;
    final merchant = _extractMerchant(anchorLine, isExpense);
    if (merchant == null) return null;

    final amount = _extractAmount(lines);
    if (amount == null) return null;

    final timestamp = _extractTimestamp(lines);
    String? upiId;
    for (final l in lines) {
      final m = _upiIdRegex.firstMatch(l);
      if (m != null) {
        upiId = m.group(1);
        break;
      }
    }
    final account = _extractAccountInfo(lines);

    final ts = timestamp ?? DateTime.now();
    final bankName = account.bankName ?? 'Google Pay';

    return ParsedTransaction(
      amount: amount,
      type: type,
      merchant: merchant,
      reference: upiId,
      accountLast4: account.last4,
      balance: null,
      creditLimit: null,
      sourceText: block,
      sender: 'GPay PDF',
      timestamp: ts,
      bankName: bankName,
      transactionId: stableTransactionId(
          'GPay PDF|$amount|${upiId ?? ''}|${ts.millisecondsSinceEpoch}'),
      isFromCard: false,
      currency: 'INR',
      fromAccount: null,
      toAccount: null,
    );
  }

  // ─── Field extractors ─────────────────────────────────────────────────────

  String? _extractMerchant(String anchorLine, bool isExpense) {
    final regex = isExpense ? _merchantAnchorRegex : _receivedAnchorRegex;
    final m = regex.firstMatch(anchorLine);
    final value = m?.group(1)?.trim();
    if (value == null || value.isEmpty) return null;
    return value;
  }

  /// Returns the amount as a normalized numeric string (commas stripped).
  String? _extractAmount(List<String> lines) {
    for (final line in lines) {
      final m = _amountRegex.firstMatch(line);
      if (m == null) continue;
      final cleaned = m.group(1)!.replaceAll(',', '');
      if (double.tryParse(cleaned) != null) return cleaned;
    }
    return null;
  }

  /// Assembles timestamp from up to three separate lines:
  ///   "01 Sep,"  → day=1, month=Sep
  ///   "2025"     → year
  ///   "03:02 PM" → time
  /// Also handles the full-date row form "15 Oct, 2025" + "11:08 AM".
  DateTime? _extractTimestamp(List<String> lines) {
    String? dateLine;
    String? yearLine;
    String? timeLine;

    for (final line in lines) {
      if (dateLine == null &&
          (_dateLineRegex.hasMatch(line) || _fullDateLineRegex.hasMatch(line))) {
        dateLine = line;
      } else if (yearLine == null && _yearLineRegex.hasMatch(line)) {
        yearLine = line;
      } else if (timeLine == null && _timeLineRegex.hasMatch(line)) {
        final m = _timeLineRegex.firstMatch(line);
        timeLine = '${m!.group(1)} ${m.group(2)}';
      }
      final haveDate = dateLine != null &&
          (yearLine != null || _fullDateLineRegex.hasMatch(dateLine));
      if (haveDate && timeLine != null) break;
    }

    if (dateLine == null || timeLine == null) return null;
    final isFullDate = _fullDateLineRegex.hasMatch(dateLine);
    if (!isFullDate && yearLine == null) return null;

    // Parse day + month.
    int day;
    int month;
    int year;
    if (isFullDate) {
      // "15 Oct, 2025"
      final m = RegExp(r'^(\d{1,2})\s+(\w{3}),\s+(20\d{2})$').firstMatch(dateLine);
      if (m == null) return null;
      day = int.parse(m.group(1)!);
      month = kMonthAbbreviations[m.group(2)!.toLowerCase()] ?? 0;
      year = int.parse(m.group(3)!);
    } else {
      final m = _dateLineRegex.firstMatch(dateLine);
      if (m == null) return null;
      day = int.parse(m.group(1)!);
      month = kMonthAbbreviations[m.group(2)!.toLowerCase()] ?? 0;
      year = int.parse(yearLine!);
    }
    if (month == 0) return null;

    // Parse time "03:02 PM".
    final tm = RegExp(r'^(\d{1,2}):(\d{2})\s*([AaPp][Mm])$').firstMatch(timeLine);
    if (tm == null) return null;
    var hour = int.parse(tm.group(1)!);
    final minute = int.parse(tm.group(2)!);
    final meridiem = tm.group(3)!.toUpperCase();
    if (meridiem == 'PM' && hour != 12) hour += 12;
    if (meridiem == 'AM' && hour == 12) hour = 0;

    return istDateTime(year, month, day, hour, minute);
  }

  _RowParts _splitAnchorAndAmount(String value) {
    final m = _trailingAmountRegex.firstMatch(value);
    if (m == null) return _RowParts(value.trim(), null);
    final anchorLine = value.substring(0, m.start).trim();
    return _RowParts(anchorLine, m.group(1)!.trim());
  }

  /// Extracts bank name and last 4 digits from the account line.
  /// Expense: "Paid by South Indian Bank 1234"
  /// Income:  "Paid to South Indian Bank 1234"
  _AccountInfo _extractAccountInfo(List<String> lines) {
    String? accountLine;
    for (final l in lines) {
      if (_bankAccountLineRegex.hasMatch(l)) {
        accountLine = l;
        break;
      }
    }
    if (accountLine == null) return const _AccountInfo(null, null);

    final m = _bankAccountLineRegex.firstMatch(accountLine);
    String? bankName;
    if (m != null) {
      final first = m.group(1)?.trim();
      final second = m.group(2)?.trim();
      final combined = [first, second].where((s) => s != null && s.isNotEmpty).join(' ');
      bankName = combined.isNotEmpty ? combined : null;
    }
    final last4 = m?.group(3)?.trim();
    return _AccountInfo(bankName, last4);
  }
}

class _AccountInfo {
  final String? bankName;
  final String? last4;
  const _AccountInfo(this.bankName, this.last4);
}

class _RowParts {
  final String anchorLine;
  final String? amountLine;
  const _RowParts(this.anchorLine, this.amountLine);
}
