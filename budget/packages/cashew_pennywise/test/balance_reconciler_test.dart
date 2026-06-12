import 'package:flutter_test/flutter_test.dart';

import 'package:cashew_pennywise/src/capture/balance_reconciler.dart';
import 'package:cashew_pennywise/src/parsed_transaction.dart';

/// Covers the ported branches of PennyWise's `processBalanceUpdate` decision
/// logic. Cashew applies the result as a balance-correction transaction, so the
/// key outputs are [authoritativeBalance] and [correctionDelta].
void main() {
  const reconciler = BalanceReconciler();

  group('reported balance is authoritative', () {
    test('uses reported balance and computes the delta to reach it', () {
      final r = reconciler.reconcile(
        reportedBalance: 34567.67,
        computedBalance: 34000.00,
        type: ParsedTransactionType.expense,
        isFromCard: false,
        amount: 100,
      );
      expect(r.usedReportedBalance, isTrue);
      expect(r.authoritativeBalance, 34567.67);
      expect(r.needsCorrection, isTrue);
      expect(r.correctionDelta, closeTo(567.67, 1e-9));
    });

    test('no correction when computed already matches reported (tolerance)', () {
      final r = reconciler.reconcile(
        reportedBalance: 1000.00,
        computedBalance: 1000.004, // within 0.5*10^-2 = 0.005
        type: ParsedTransactionType.income,
        isFromCard: false,
        amount: 50,
      );
      expect(r.needsCorrection, isFalse);
      expect(r.correctionDelta, 0.0);
    });

    test('correction when drift exceeds tolerance', () {
      final r = reconciler.reconcile(
        reportedBalance: 1000.00,
        computedBalance: 999.50,
        type: ParsedTransactionType.income,
        isFromCard: false,
        amount: 50,
      );
      expect(r.needsCorrection, isTrue);
      expect(r.correctionDelta, closeTo(0.50, 1e-9));
    });

    test('zero-decimal currency uses a coarser tolerance', () {
      // tolerance = 0.5*10^0 = 0.5
      final r = reconciler.reconcile(
        reportedBalance: 1000,
        computedBalance: 1000.4,
        type: ParsedTransactionType.income,
        isFromCard: false,
        amount: 5,
        decimals: 0,
      );
      expect(r.needsCorrection, isFalse);
    });
  });

  group('derived balance (no reported balance)', () {
    test('income adds to previous balance', () {
      final r = reconciler.reconcile(
        reportedBalance: null,
        computedBalance: 0,
        type: ParsedTransactionType.income,
        isFromCard: false,
        previousBalance: 1000,
        amount: 250,
      );
      expect(r.usedReportedBalance, isFalse);
      expect(r.authoritativeBalance, 1250);
    });

    test('expense subtracts from previous balance', () {
      final r = reconciler.reconcile(
        reportedBalance: null,
        computedBalance: 0,
        type: ParsedTransactionType.expense,
        isFromCard: false,
        previousBalance: 1000,
        amount: 250,
      );
      expect(r.authoritativeBalance, 750);
    });

    test('investment subtracts from previous balance', () {
      final r = reconciler.reconcile(
        reportedBalance: null,
        computedBalance: 0,
        type: ParsedTransactionType.investment,
        isFromCard: false,
        previousBalance: 1000,
        amount: 400,
      );
      expect(r.authoritativeBalance, 600);
    });

    test('expense clamps at zero (does not go negative)', () {
      final r = reconciler.reconcile(
        reportedBalance: null,
        computedBalance: 0,
        type: ParsedTransactionType.expense,
        isFromCard: false,
        previousBalance: 100,
        amount: 250,
      );
      expect(r.authoritativeBalance, 0);
    });

    test('null previous balance is treated as zero', () {
      final r = reconciler.reconcile(
        reportedBalance: null,
        computedBalance: 0,
        type: ParsedTransactionType.income,
        isFromCard: false,
        previousBalance: null,
        amount: 75,
      );
      expect(r.authoritativeBalance, 75);
    });

    test('transfer keeps the previous balance (ambiguous)', () {
      final r = reconciler.reconcile(
        reportedBalance: null,
        computedBalance: 0,
        type: ParsedTransactionType.transfer,
        isFromCard: false,
        previousBalance: 500,
        amount: 100,
      );
      expect(r.authoritativeBalance, 500);
    });
  });

  group('credit card outstanding', () {
    test('credit spend grows outstanding (previous + amount)', () {
      final r = reconciler.reconcile(
        reportedBalance: null,
        computedBalance: 0,
        type: ParsedTransactionType.credit,
        isFromCard: true,
        previousBalance: 2000,
        amount: 500,
      );
      expect(r.authoritativeBalance, 2500);
    });

    test('income onto a card shrinks outstanding (clamped at zero)', () {
      final r = reconciler.reconcile(
        reportedBalance: null,
        computedBalance: 0,
        type: ParsedTransactionType.income,
        isFromCard: true,
        previousBalance: 300,
        amount: 500,
      );
      expect(r.authoritativeBalance, 0);
    });

    test('partial credit-card payment reduces outstanding', () {
      final r = reconciler.reconcile(
        reportedBalance: null,
        computedBalance: 0,
        type: ParsedTransactionType.income,
        isFromCard: true,
        previousBalance: 2000,
        amount: 500,
      );
      expect(r.authoritativeBalance, 1500);
    });
  });
}
