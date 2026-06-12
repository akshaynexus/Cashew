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
/// Credit-card semantics (the v2 extension): in PennyWise the persisted
/// balance for a credit card is the **outstanding** amount — it *grows* on
/// spend and *shrinks* on payment — and `creditLimit` is the **available**
/// limit. Cashew has no separate outstanding field; a credit-card *wallet*
/// instead carries a (typically negative) running balance where spending
/// pushes it more negative and payments pull it toward zero. So for a credit
/// card the authoritative *Cashew wallet* balance is the negation of the
/// outstanding amount. [reconcile] returns balances already expressed in
/// Cashew's wallet-balance convention, so the caller can diff against
/// `computedBalance` directly regardless of card vs. debit.
///
/// Outstanding is resolved (for cards) in priority order:
///  1. SMS-reported balance, if present (the bank stated outstanding directly).
///  2. Else, if `creditLimit` (available limit) and `totalCreditLimit` are both
///     known: `outstanding = totalCreditLimit - availableLimit`.
///  3. Else derive from the prior outstanding and the transaction:
///       - credit/expense spend -> previousOutstanding + amount
///       - income (payment)     -> max(previousOutstanding - amount, 0)
///
/// Authoritative-balance rules for non-card (debit/savings) accounts, in
/// priority order:
///  1. If the SMS reported a balance, that is the truth.
///  2. Else derive from type against `previousBalance`:
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
  /// - [creditLimit]: the bank-reported *available* credit limit, if any. Used
  ///   (with [totalCreditLimit]) to derive outstanding when no balance is
  ///   reported on a credit card.
  /// - [totalCreditLimit]: the card's total/sanctioned credit limit, if known
  ///   (e.g. from the wallet config). With [creditLimit] this yields
  ///   `outstanding = total - available`.
  BalanceReconcileResult reconcile({
    required double? reportedBalance,
    required double computedBalance,
    required ParsedTransactionType type,
    required bool isFromCard,
    double? previousBalance,
    double? amount,
    int decimals = 2,
    double? creditLimit,
    double? totalCreditLimit,
  }) {
    final tolerance = 0.5 * _pow10(-decimals);
    final prev = previousBalance ?? 0.0;
    final amt = (amount ?? 0.0).abs();

    // A credit card is signalled either by the parser type CREDIT or by the
    // message originating from a card (isFromCard). Mirrors PennyWise's
    // `isCreditCard` check in processBalanceUpdate.
    final isCreditCard =
        isFromCard || type == ParsedTransactionType.credit;

    final double authoritative;
    final bool usedReported;

    if (isCreditCard) {
      // Credit cards reconcile on OUTSTANDING. Cashew represents a card
      // wallet's balance as the negation of outstanding (spend -> more
      // negative), so we resolve outstanding first then negate.
      final double outstanding;
      if (reportedBalance != null) {
        // Bank stated outstanding directly.
        outstanding = reportedBalance;
        usedReported = true;
      } else if (creditLimit != null && totalCreditLimit != null) {
        // outstanding = total limit - available limit.
        outstanding = _clampNonNegative(totalCreditLimit - creditLimit);
        usedReported = false;
      } else {
        usedReported = false;
        final prevOutstanding = prev < 0 ? -prev : prev;
        if (type == ParsedTransactionType.income) {
          // Payment onto the card shrinks outstanding.
          outstanding = _clampNonNegative(prevOutstanding - amt);
        } else {
          // Spend (credit/expense/etc.) grows outstanding.
          outstanding = prevOutstanding + amt;
        }
      }
      // Express in Cashew wallet-balance convention: negative of outstanding.
      authoritative = -outstanding;
    } else if (reportedBalance != null) {
      // Debit/savings rule 1: prefer the SMS-reported balance.
      authoritative = reportedBalance;
      usedReported = true;
    } else {
      usedReported = false;
      // Debit/savings rule 2: derive from type.
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
