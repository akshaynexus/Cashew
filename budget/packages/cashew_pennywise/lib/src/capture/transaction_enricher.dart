import '../parsed_transaction.dart';

/// A minimal transaction shape used by [TransactionEnricher]. Carries only the
/// fields needed to decide whether a statement (GPay/PhonePe PDF) transaction
/// should enrich an already-captured one.
///
/// Cashew transactions have no separate from/to-account or description columns,
/// so the Cashew glue uses only the **merchant** enrichment path. The model
/// keeps the merchant; from/to-account and description from PennyWise are
/// intentionally dropped (see fidelity caveats in the port report).
class EnrichCandidate {
  /// Numeric magnitude of the transaction (always positive).
  final num amount;
  final String currency;
  final ParsedTransactionType type;

  /// UPI reference / RRN, if any.
  final String? reference;

  /// Merchant / payee name (may be generic, e.g. "UPI Transaction").
  final String? merchant;

  /// Last 4 digits of the account, if known.
  final String? accountLast4;

  final DateTime timestamp;

  const EnrichCandidate({
    required this.amount,
    required this.currency,
    required this.type,
    required this.reference,
    required this.merchant,
    required this.accountLast4,
    required this.timestamp,
  });
}

/// Generic merchant strings PennyWise considers "not real" — the parser emits
/// these for bare UPI/Google-Pay payments where the payee couldn't be resolved.
/// Compared case-insensitively. Mirrors `StatementTransactionEnricher.genericValues`.
const Set<String> kGenericMerchantValues = {
  '',
  'unknown',
  'unknown merchant',
  'upi',
  'upi transaction',
  'upi payment',
  'upi credit',
  'payment',
  'google pay',
};

/// Tolerance for matching a statement transaction to an existing one by
/// timestamp. Mirrors `StatementTransactionEnricher.MATCH_WINDOW`.
const Duration kEnrichMatchWindow = Duration(minutes: 5);

/// Pure-Dart port of PennyWise's `StatementTransactionEnricher`.
///
/// When a GPay/PhonePe PDF statement is imported, it often carries the real
/// merchant name for a payment that an earlier SMS captured only generically
/// (e.g. "UPI Transaction"). This decides whether the statement transaction
/// matches an existing one, and, if so, upgrades the merchant name.
class TransactionEnricher {
  const TransactionEnricher();

  /// Strong match: same non-blank reference AND same transaction details
  /// (amount/currency/type/account within the window). Ports `isStatementMatch`.
  bool isStatementMatch(EnrichCandidate existing, EnrichCandidate statement) {
    final existingRef = (existing.reference ?? '').trim();
    final statementRef = (statement.reference ?? '').trim();
    if (existingRef.isEmpty || existingRef != statementRef) return false;
    return hasSameTransactionDetails(existing, statement);
  }

  /// Fallback match (no/blank reference): same details within the window AND
  /// the statement actually has usable detail to add. Ports `isFallbackStatementMatch`.
  bool isFallbackStatementMatch(
      EnrichCandidate existing, EnrichCandidate statement) {
    if (!hasSameTransactionDetails(existing, statement)) return false;
    return hasUsableStatementDetails(existing, statement);
  }

  /// Loosest candidate: same amount/currency/type/account (ignoring the time
  /// window — e.g. a PDF row dated to midnight) and the statement has usable
  /// detail. Ports `isAmountDateFallbackEnrichmentCandidate`.
  bool isAmountDateFallbackEnrichmentCandidate(
      EnrichCandidate existing, EnrichCandidate statement) {
    if (!_amountsEqual(existing.amount, statement.amount)) return false;
    if (existing.currency != statement.currency) return false;
    if (existing.type != statement.type) return false;
    if (!accountsMatch(existing.accountLast4, statement.accountLast4)) {
      return false;
    }
    return hasUsableStatementDetails(existing, statement);
  }

  /// Ports `hasUsableStatementDetails`. Cashew only carries a merchant, so only
  /// the merchant arm of PennyWise's condition is evaluated.
  bool hasUsableStatementDetails(
      EnrichCandidate existing, EnrichCandidate statement) {
    return canUseStatementValue(existing.merchant, statement.merchant);
  }

  /// True if amount/currency/type/account agree and the timestamps fall within
  /// [kEnrichMatchWindow]. Ports `hasSameTransactionDetails`.
  bool hasSameTransactionDetails(
      EnrichCandidate existing, EnrichCandidate statement) {
    if (!_amountsEqual(existing.amount, statement.amount)) return false;
    if (existing.currency != statement.currency) return false;
    if (existing.type != statement.type) return false;
    if (!accountsMatch(existing.accountLast4, statement.accountLast4)) {
      return false;
    }
    final gap = existing.timestamp.difference(statement.timestamp).abs();
    return gap <= kEnrichMatchWindow;
  }

  /// True if the [statement] value is real (non-blank, non-generic) AND the
  /// [existing] value is blank/generic — i.e. worth upgrading. Ports `canUseStatementValue`.
  bool canUseStatementValue(String? existing, String? statement) {
    final incoming = (statement ?? '').trim();
    if (incoming.isEmpty || isGeneric(incoming)) return false;
    final current = (existing ?? '').trim();
    return current.isEmpty || isGeneric(current);
  }

  /// Ports `isGeneric`.
  bool isGeneric(String value) =>
      kGenericMerchantValues.contains(value.trim().toLowerCase());

  /// Accounts match if either side is unknown/blank or they are equal.
  /// Ports `accountsMatch`.
  bool accountsMatch(String? existing, String? statement) {
    return existing == null ||
        existing.isEmpty ||
        statement == null ||
        statement.isEmpty ||
        existing == statement;
  }

  /// The merchant to use after enrichment: the statement merchant if it upgrades
  /// the existing one, else the existing merchant. Ports the merchant arm of `enrich`.
  String? enrich(EnrichCandidate existing, EnrichCandidate statement) {
    if (canUseStatementValue(existing.merchant, statement.merchant)) {
      return statement.merchant;
    }
    return existing.merchant;
  }

  /// The upgraded merchant if enrichment applies, else null (no change).
  String? enrichedMerchant(EnrichCandidate existing, EnrichCandidate statement) {
    if (canUseStatementValue(existing.merchant, statement.merchant)) {
      return statement.merchant;
    }
    return null;
  }

  bool _amountsEqual(num a, num b) => (a - b).abs() < 1e-9;
}
