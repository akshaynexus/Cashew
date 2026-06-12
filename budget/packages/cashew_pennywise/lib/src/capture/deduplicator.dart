import '../parsed_transaction.dart';

/// Pure-Dart port of PennyWise's `TransactionDeduplication`.
///
/// Decides whether a [ParsedTransaction] duplicates one already captured. Two
/// rules, mirroring the Kotlin object:
///
///  1. **Stable id match** — same `transactionId` (PennyWise's
///     `transactionHash`). An exact match is always a duplicate.
///  2. **UPI reference match** — both sides carry a 12-digit UPI RRN
///     `reference`, and they agree on reference + type + currency + amount +
///     (compatible) account, and their timestamps fall within
///     [upiDuplicateWindow] (±3 minutes). This catches the common case where
///     the same UPI payment is reported twice (e.g. by a partner bank and the
///     account bank) with *different* generated ids.
///
/// This is intentionally standalone and reusable: [SmsScanner] does its own
/// within-scan dedup, but the capture orchestrator needs the same rules to
/// compare an incoming transaction against what is already persisted.
class CaptureDeduplicator {
  const CaptureDeduplicator();

  /// UPI references are 12-digit RRNs. Matches PennyWise's `upiReferencePattern`.
  static final RegExp _upiReference = RegExp(r'^\d{12}$');

  /// PennyWise's `UPI_DUPLICATE_WINDOW`.
  static const Duration upiDuplicateWindow = Duration(minutes: 3);

  /// True if [transaction] carries a 12-digit UPI reference.
  /// Ports `TransactionDeduplication.hasUpiReference`.
  bool hasUpiReference(ParsedTransaction transaction) {
    final ref = transaction.reference;
    return ref != null && _upiReference.hasMatch(ref);
  }

  /// True if [existing] and [incoming] are the same UPI transaction reported
  /// twice within [window]. Ports `isSameUpiTransaction`.
  bool isSameUpiTransaction(
    ParsedTransaction existing,
    ParsedTransaction incoming, {
    Duration window = upiDuplicateWindow,
  }) {
    if (!hasUpiReference(existing) || !hasUpiReference(incoming)) return false;
    if (existing.reference != incoming.reference) return false;
    if (existing.type != incoming.type) return false;
    if (existing.currency != incoming.currency) return false;
    if (!_amountsEqual(existing.amount, incoming.amount)) return false;
    if (!_accountsMatch(existing.accountLast4, incoming.accountLast4)) {
      return false;
    }
    final gap = existing.timestamp.difference(incoming.timestamp).abs();
    return gap <= window;
  }

  /// True if [candidate] duplicates any transaction in [existing].
  ///
  /// Rule 1 (transactionId) is checked first; rule 2 (UPI window) second.
  bool isDuplicate(
    ParsedTransaction candidate,
    Iterable<ParsedTransaction> existing,
  ) {
    final candidateId = candidate.transactionId;
    for (final other in existing) {
      if (candidateId.isNotEmpty && other.transactionId == candidateId) {
        return true;
      }
      if (isSameUpiTransaction(other, candidate)) {
        return true;
      }
    }
    return false;
  }

  /// Collapses duplicates *within a batch*, preserving order. The first
  /// occurrence of each distinct transaction is kept; later duplicates (by
  /// transactionId or UPI window) are dropped.
  ///
  /// Note: unlike PennyWise's `duplicateIdsToDelete` (which picks a "best
  /// quality" keeper for an already-persisted set), this batch helper keeps the
  /// *first-seen* item, matching [SmsScanner]'s streaming semantics where the
  /// earlier message has already been emitted/persisted.
  List<ParsedTransaction> dropDuplicates(List<ParsedTransaction> batch) {
    final kept = <ParsedTransaction>[];
    for (final tx in batch) {
      if (isDuplicate(tx, kept)) continue;
      kept.add(tx);
    }
    return kept;
  }

  /// Accounts match if either side is unknown/blank, or they are equal.
  /// Ports `accountsMatch`.
  bool _accountsMatch(String? existing, String? incoming) {
    return existing == null ||
        existing.isEmpty ||
        incoming == null ||
        incoming.isEmpty ||
        existing == incoming;
  }

  /// Numeric amount equality (parser keeps amounts as strings to preserve
  /// precision). Mirrors `BigDecimal.compareTo(...) == 0`.
  bool _amountsEqual(String a, String b) {
    if (a == b) return true;
    final da = double.tryParse(a);
    final db = double.tryParse(b);
    if (da == null || db == null) return false;
    return da == db;
  }
}
