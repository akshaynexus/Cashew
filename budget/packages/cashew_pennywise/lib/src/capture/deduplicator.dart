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

  // ---------------------------------------------------------------------------
  // Quality-based dedup (ports the parts of `TransactionDeduplication` that pick
  // a "best" record when the same UPI payment is reported twice — typically by a
  // partner bank like SBI and the actual account bank).
  // ---------------------------------------------------------------------------

  static const String _partnerBankName = 'State Bank of India';

  bool _isPartnerBank(String? bankName) =>
      (bankName ?? '').toLowerCase() == _partnerBankName.toLowerCase();

  /// Ports `shouldReplaceWithIncoming`. Only applies when the two are the same
  /// UPI transaction. Prefers the non-partner (non-SBI) bank; on a tie, prefers
  /// the record that carries a balance.
  bool shouldReplaceWithIncoming(
    DedupCandidate existing,
    DedupCandidate incoming,
  ) {
    if (!_isSameUpiCandidate(existing, incoming)) return false;

    final existingIsPartner = _isPartnerBank(existing.bankName);
    final incomingIsPartner = _isPartnerBank(incoming.bankName);
    if (existingIsPartner && !incomingIsPartner) return true;
    if (!existingIsPartner && incomingIsPartner) return false;

    return existing.balance == null && incoming.balance != null;
  }

  /// Ports `duplicateIdsToDelete`. Given persisted candidates, clusters same-UPI
  /// duplicates and returns the ids to delete, keeping the highest-quality record
  /// per cluster (non-SBI, has-balance, earliest time, lowest id).
  List<I> duplicateIdsToDelete<I>(Iterable<DedupCandidate<I>> transactions) {
    final groups = <String, List<DedupCandidate<I>>>{};
    for (final t in transactions) {
      if (!_hasUpiReferenceStr(t.reference)) continue;
      final key = [
        t.reference ?? '',
        _normalizedAmount(t.amount),
        t.accountLast4 ?? '',
        t.type.name,
        t.currency,
      ].join('|');
      (groups[key] ??= <DedupCandidate<I>>[]).add(t);
    }

    final result = <I>[];
    for (final group in groups.values) {
      result.addAll(_duplicateIdsFromGroup(group));
    }
    return result;
  }

  List<I> _duplicateIdsFromGroup<I>(List<DedupCandidate<I>> group) {
    final sorted = [...group]..sort(_byTimeThenId);

    final clusters = <List<DedupCandidate<I>>>[];
    for (final tx in sorted) {
      final cluster = clusters.firstWhere(
        (c) => c.any((prev) => _isSameUpiCandidate(prev, tx)),
        orElse: () => <DedupCandidate<I>>[],
      );
      if (cluster.isEmpty) {
        clusters.add([tx]);
      } else {
        cluster.add(tx);
      }
    }

    final ids = <I>[];
    for (final cluster in clusters) {
      final keeper = cluster.reduce(
          (a, b) => _qualityComparator(a, b) <= 0 ? a : b);
      final toDelete = cluster
          .where((t) => t.id != keeper.id)
          .toList()
        ..sort(_byTimeThenId);
      ids.addAll(toDelete.map((t) => t.id));
    }
    return ids;
  }

  /// Lower is better. Ports `transactionQualityComparator`: non-SBI first,
  /// has-balance first, then earliest time, then lowest id.
  int _qualityComparator(DedupCandidate a, DedupCandidate b) {
    final ap = _isPartnerBank(a.bankName) ? 1 : 0;
    final bp = _isPartnerBank(b.bankName) ? 1 : 0;
    if (ap != bp) return ap - bp;

    final ab = a.balance == null ? 1 : 0;
    final bb = b.balance == null ? 1 : 0;
    if (ab != bb) return ab - bb;

    final t = a.timestamp.compareTo(b.timestamp);
    if (t != 0) return t;

    return _compareIds(a.id, b.id);
  }

  int _byTimeThenId(DedupCandidate a, DedupCandidate b) {
    final t = a.timestamp.compareTo(b.timestamp);
    if (t != 0) return t;
    return _compareIds(a.id, b.id);
  }

  int _compareIds(Object? a, Object? b) {
    if (a is Comparable && b is Comparable) {
      try {
        return a.compareTo(b);
      } catch (_) {
        return a.toString().compareTo(b.toString());
      }
    }
    return a.toString().compareTo(b.toString());
  }

  bool _hasUpiReferenceStr(String? ref) =>
      ref != null && _upiReference.hasMatch(ref);

  bool _isSameUpiCandidate(DedupCandidate a, DedupCandidate b,
      {Duration window = upiDuplicateWindow}) {
    if (!_hasUpiReferenceStr(a.reference) ||
        !_hasUpiReferenceStr(b.reference)) {
      return false;
    }
    if (a.reference != b.reference) return false;
    if (a.type != b.type) return false;
    if (a.currency != b.currency) return false;
    if (!_amountsEqual(a.amount, b.amount)) return false;
    if (!_accountsMatch(a.accountLast4, b.accountLast4)) return false;
    final gap = a.timestamp.difference(b.timestamp).abs();
    return gap <= window;
  }

  String _normalizedAmount(String amount) {
    final d = double.tryParse(amount);
    if (d == null) return amount;
    // Strip trailing zeros, matching BigDecimal.stripTrailingZeros().
    var s = d.toString();
    if (s.contains('.')) {
      s = s.replaceAll(RegExp(r'0+$'), '').replaceAll(RegExp(r'\.$'), '');
    }
    return s;
  }
}

/// A candidate record for quality-based dedup ([CaptureDeduplicator.duplicateIdsToDelete]
/// / [CaptureDeduplicator.shouldReplaceWithIncoming]). Generic over the id type
/// [I] (row id, UUID string, etc.). Mirrors the fields of PennyWise's
/// `TransactionEntity` needed by the dedup quality logic.
class DedupCandidate<I> {
  final I id;
  final String? reference;
  final String amount;
  final ParsedTransactionType type;
  final String currency;
  final String? accountLast4;
  final DateTime timestamp;
  final String? bankName;

  /// Bank-reported running balance after this transaction, if any. Records that
  /// carry a balance are preferred over those that don't.
  final num? balance;

  const DedupCandidate({
    required this.id,
    required this.reference,
    required this.amount,
    required this.type,
    required this.currency,
    required this.accountLast4,
    required this.timestamp,
    required this.bankName,
    required this.balance,
  });
}
