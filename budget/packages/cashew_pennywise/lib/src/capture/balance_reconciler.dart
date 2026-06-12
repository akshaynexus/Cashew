import '../parsed_transaction.dart';

/// Outcome of a balance reconciliation decision.
class BalanceReconcileResult {
  /// The balance we believe to be authoritative after this transaction.
  /// This is either the bank-reported balance (preferred) or a derived one.
  final double authoritativeBalance;

  /// The signed delta to apply to Cashew's computed balance so it matches
  /// [authoritativeBalance]. `0.0` when the computed balance is already within
  /// tolerance (no correction needed).
  ///
  /// Apply as: `createCorrectionTransaction(correctionDelta, wallet, ...)`.
  final double correctionDelta;

  /// True when [correctionDelta] is non-zero and a correction should be made.
  final bool needsCorrection;

  /// True when [authoritativeBalance] came straight from the SMS-reported
  /// balance (vs. being derived from the transaction type). Informational.
  final bool usedReportedBalance;

  const BalanceReconcileResult({
    required this.authoritativeBalance,
    required this.correctionDelta,
    required this.needsCorrection,
    required this.usedReportedBalance,
  });

  @override
  String toString() => 'BalanceReconcileResult(authoritative='
      '$authoritativeBalance, delta=$correctionDelta, '
      'needsCorrection=$needsCorrection, reported=$usedReportedBalance)';
}

/// Pure-Dart port of the *decision* logic in PennyWise's
/// `SmsTransactionProcessor.processBalanceUpdate` (lines ~200-313).
///
/// PennyWise persists an `AccountBalanceEntity`; Cashew instead reconciles a
/// wallet's running balance via a balance-correction transaction. This class
/// keeps only the math: given the bank-reported balance (if any), the balance
/// Cashew currently computes, and the transaction shape, it returns the
/// authoritative balance and the correction delta needed to reach it.
///
/// Authoritative-balance rules (ported, in priority order):
///  1. If the SMS reported a balance, that is the truth.
///  2. Else, for a credit card, outstanding *grows* on spend: `previous + amount`.
///  3. Else, for an income onto a credit card, outstanding *shrinks* on payment:
///     `max(previous - amount, 0)`.
///  4. Else derive from type against `previousBalance`:
///       - income  -> previous + amount
///       - expense/investment -> max(previous - amount, 0)
///       - credit/transfer    -> previous (unchanged; ambiguous)
///
/// A correction is only emitted when the gap between the authoritative balance
/// and Cashew's [computedBalance] exceeds a tolerance of `0.5 * 10^-decimals`
/// (half a minor unit), avoiding floating-point/rounding spam.
class BalanceReconciler {
  const BalanceReconciler();

  /// Computes the reconciliation decision.
  ///
  /// - [reportedBalance]: the balance the SMS itself stated, or null.
  /// - [computedBalance]: the wallet balance Cashew currently computes.
  /// - [type]: the parsed transaction type (sign/derivation driver).
  /// - [isFromCard]: whether the source was a card message.
  /// - [previousBalance]: the last known authoritative balance for derivation
  ///   (null is treated as 0, matching PennyWise's `BigDecimal.ZERO` default).
  /// - [amount]: the magnitude of the transaction (positive). When null, it is
  ///   not needed because [reportedBalance] is present.
  /// - [decimals]: currency minor-unit digits (2 for most; 0 for e.g. JPY).
  BalanceReconcileResult reconcile({
    required double? reportedBalance,
    required double computedBalance,
    required ParsedTransactionType type,
    required bool isFromCard,
    double? previousBalance,
    double? amount,
    int decimals = 2,
  }) {
    final tolerance = 0.5 * _pow10(-decimals);
    final prev = previousBalance ?? 0.0;
    final amt = (amount ?? 0.0).abs();
    final isCreditCard = isFromCard && type == ParsedTransactionType.credit ||
        type == ParsedTransactionType.credit;

    final double authoritative;
    final bool usedReported;

    if (reportedBalance != null) {
      // Rule 1: prefer the SMS-reported balance.
      authoritative = reportedBalance;
      usedReported = true;
    } else {
      usedReported = false;
      if (isCreditCard) {
        // Rule 2: credit-card outstanding grows on spend.
        authoritative = prev + amt;
      } else if (type == ParsedTransactionType.income && isFromCard) {
        // Rule 3: payment onto a credit card shrinks outstanding.
        authoritative = _clampNonNegative(prev - amt);
      } else {
        // Rule 4: derive from type.
        switch (type) {
          case ParsedTransactionType.income:
            authoritative = prev + amt;
            break;
          case ParsedTransactionType.expense:
          case ParsedTransactionType.investment:
            authoritative = _clampNonNegative(prev - amt);
            break;
          case ParsedTransactionType.credit:
          case ParsedTransactionType.transfer:
          case ParsedTransactionType.balanceUpdate:
            // Ambiguous direction: keep existing balance.
            authoritative = prev;
            break;
        }
      }
    }

    final delta = authoritative - computedBalance;
    final needsCorrection = delta.abs() > tolerance;
    return BalanceReconcileResult(
      authoritativeBalance: authoritative,
      correctionDelta: needsCorrection ? delta : 0.0,
      needsCorrection: needsCorrection,
      usedReportedBalance: usedReported,
    );
  }

  double _clampNonNegative(double v) => v < 0 ? 0.0 : v;

  double _pow10(int exp) {
    var result = 1.0;
    final n = exp.abs();
    for (var i = 0; i < n; i++) {
      result *= 10;
    }
    return exp < 0 ? 1 / result : result;
  }
}
