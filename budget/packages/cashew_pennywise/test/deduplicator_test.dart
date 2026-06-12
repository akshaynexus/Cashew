import 'package:flutter_test/flutter_test.dart';

import 'package:cashew_pennywise/src/capture/deduplicator.dart';
import 'package:cashew_pennywise/src/parsed_transaction.dart';

/// Ported from PennyWise's `TransactionDeduplicationTest`, adapted to Cashew's
/// `ParsedTransaction` shape (transactionId instead of row id; string amount).
void main() {
  const dedup = CaptureDeduplicator();
  final baseTime = DateTime(2025, 12, 26, 19, 2, 1);

  ParsedTransaction tx({
    required String id,
    String amount = '15000.00',
    String? accountLast4 = '2468',
    String bankName = 'South Indian Bank',
    String? reference = '111222333444',
    DateTime? timestamp,
    ParsedTransactionType type = ParsedTransactionType.income,
    String currency = 'INR',
  }) =>
      ParsedTransaction(
        amount: amount,
        type: type,
        merchant: 'Sample Merchant',
        reference: reference,
        accountLast4: accountLast4,
        balance: null,
        creditLimit: null,
        sourceText: 'sample sms',
        sender: 'SIBSMS',
        timestamp: timestamp ?? baseTime,
        bankName: bankName,
        transactionId: id,
        isFromCard: false,
        currency: currency,
        fromAccount: null,
        toAccount: null,
      );

  group('isSameUpiTransaction', () {
    test('matches same UPI reference within the window', () {
      final a = tx(id: '1', timestamp: baseTime);
      final b = tx(id: '2', timestamp: baseTime.add(const Duration(minutes: 2)));
      expect(dedup.isSameUpiTransaction(a, b), isTrue);
    });

    test('does not match outside the 3-minute window', () {
      final first = tx(id: '1', timestamp: baseTime);
      final later =
          tx(id: '2', timestamp: baseTime.add(const Duration(minutes: 4)));
      expect(dedup.isSameUpiTransaction(first, later), isFalse);
    });

    test('does not match different account with same reference', () {
      final first = tx(id: '1', accountLast4: '2468');
      final other = tx(id: '2', accountLast4: '1357');
      expect(dedup.isSameUpiTransaction(first, other), isFalse);
    });

    test('matches when one side has an unknown account', () {
      final first = tx(id: '1', accountLast4: '2468');
      final other = tx(id: '2', accountLast4: null);
      expect(dedup.isSameUpiTransaction(first, other), isTrue);
    });

    test('does not match non-UPI references', () {
      final first = tx(id: '1', reference: 'ABC123');
      final second = tx(id: '2', reference: 'ABC123');
      expect(dedup.isSameUpiTransaction(first, second), isFalse);
    });

    test('does not match different amounts', () {
      final first = tx(id: '1', amount: '15000.00');
      final second = tx(id: '2', amount: '15001.00');
      expect(dedup.isSameUpiTransaction(first, second), isFalse);
    });

    test('does not match different types', () {
      final first = tx(id: '1', type: ParsedTransactionType.income);
      final second = tx(id: '2', type: ParsedTransactionType.expense);
      expect(dedup.isSameUpiTransaction(first, second), isFalse);
    });

    test('matches across midnight within the window', () {
      final beforeMidnight = DateTime(2025, 12, 26, 23, 59, 0);
      final a = tx(id: '1', timestamp: beforeMidnight);
      final b = tx(
          id: '2', timestamp: beforeMidnight.add(const Duration(minutes: 2)));
      expect(dedup.isSameUpiTransaction(a, b), isTrue);
    });

    test('amount equality tolerates trailing-zero differences', () {
      final a = tx(id: '1', amount: '15000.0');
      final b = tx(id: '2', amount: '15000.00');
      expect(dedup.isSameUpiTransaction(a, b), isTrue);
    });
  });

  group('isDuplicate', () {
    test('exact transactionId match is a duplicate', () {
      final existing = [
        tx(id: 'same', reference: 'NONUPI', accountLast4: '0001'),
      ];
      final candidate =
          tx(id: 'same', reference: 'OTHER', accountLast4: '9999');
      expect(dedup.isDuplicate(candidate, existing), isTrue);
    });

    test('different ids but same UPI within window is a duplicate', () {
      final existing = [tx(id: 'id-A', timestamp: baseTime)];
      final candidate = tx(
          id: 'id-B', timestamp: baseTime.add(const Duration(minutes: 1)));
      expect(dedup.isDuplicate(candidate, existing), isTrue);
    });

    test('unrelated transaction is not a duplicate', () {
      final existing = [tx(id: 'id-A', reference: '111222333444')];
      final candidate = tx(id: 'id-B', reference: '999888777666');
      expect(dedup.isDuplicate(candidate, existing), isFalse);
    });

    test('empty transactionId does not collide via id rule', () {
      final existing = [tx(id: '', reference: 'NONUPI', accountLast4: '0001')];
      final candidate =
          tx(id: '', reference: 'NONUPI2', accountLast4: '0002');
      expect(dedup.isDuplicate(candidate, existing), isFalse);
    });
  });

  group('dropDuplicates', () {
    test('keeps first occurrence and drops later id duplicates', () {
      final batch = [
        tx(id: 'dup', reference: 'NONUPI', accountLast4: '1'),
        tx(id: 'uniq1', reference: 'NONUPI', accountLast4: '2'),
        tx(id: 'dup', reference: 'NONUPI', accountLast4: '1'),
        tx(id: 'uniq2', reference: 'NONUPI', accountLast4: '3'),
      ];
      final kept = dedup.dropDuplicates(batch);
      expect(kept.map((t) => t.transactionId).toList(),
          ['dup', 'uniq1', 'uniq2']);
    });

    test('collapses UPI duplicates with different ids', () {
      final batch = [
        tx(id: 'id-A', timestamp: baseTime),
        tx(id: 'id-B', timestamp: baseTime.add(const Duration(minutes: 1))),
      ];
      final kept = dedup.dropDuplicates(batch);
      expect(kept, hasLength(1));
      expect(kept.first.transactionId, 'id-A');
    });

    test('keeps both when outside the UPI window', () {
      final batch = [
        tx(id: 'id-A', timestamp: baseTime),
        tx(id: 'id-B', timestamp: baseTime.add(const Duration(minutes: 4))),
      ];
      expect(dedup.dropDuplicates(batch), hasLength(2));
    });
  });
}
