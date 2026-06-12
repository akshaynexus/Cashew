import 'package:flutter_test/flutter_test.dart';

import 'package:cashew_pennywise/src/capture/transaction_enricher.dart';
import 'package:cashew_pennywise/src/parsed_transaction.dart';

/// Ported from PennyWise's `StatementTransactionEnricherTest`, adapted to
/// Cashew's [EnrichCandidate] (merchant-only; no from/to-account/description).
void main() {
  const enricher = TransactionEnricher();
  final baseTime = DateTime(2025, 9, 1, 15, 2);

  EnrichCandidate tx({
    num amount = 450.00,
    ParsedTransactionType type = ParsedTransactionType.expense,
    String? reference = '111222333444',
    String? accountLast4 = '2468',
    String? merchant = 'UPI Transaction',
    DateTime? timestamp,
    String currency = 'INR',
  }) =>
      EnrichCandidate(
        amount: amount,
        currency: currency,
        type: type,
        reference: reference,
        merchant: merchant,
        accountLast4: accountLast4,
        timestamp: timestamp ?? baseTime,
      );

  test('matches same reference amount direction account and close timestamp',
      () {
    final sms = tx(merchant: 'UPI Transaction');
    final statement =
        tx(merchant: 'Sample Store', timestamp: baseTime.add(const Duration(minutes: 4)));
    expect(enricher.isStatementMatch(sms, statement), isTrue);
  });

  test('fallback matches generic transaction with same details and close timestamp',
      () {
    final sms = tx(merchant: 'UPI Transaction', reference: '');
    final statement =
        tx(merchant: 'Sample Store', timestamp: baseTime.add(const Duration(minutes: 4)));
    expect(enricher.isFallbackStatementMatch(sms, statement), isTrue);
  });

  test('fallback does not match specific merchant', () {
    final sms = tx(merchant: 'Specific Merchant', reference: '');
    final statement =
        tx(merchant: 'Sample Store', timestamp: baseTime.add(const Duration(minutes: 4)));
    expect(enricher.isFallbackStatementMatch(sms, statement), isFalse);
  });

  test('amount date fallback candidate allows same-day statement without matching time',
      () {
    final sms = tx(merchant: 'UPI Transaction', reference: '');
    final statement = tx(
        merchant: 'Sample Store', timestamp: DateTime(2025, 9, 1)); // start of day
    expect(
        enricher.isAmountDateFallbackEnrichmentCandidate(sms, statement), isTrue);
  });

  test('amount date fallback candidate still rejects opposite direction', () {
    final sms = tx(
        merchant: 'UPI Transaction',
        type: ParsedTransactionType.income,
        reference: '');
    final statement = tx(
        merchant: 'Sample Store',
        type: ParsedTransactionType.expense,
        timestamp: DateTime(2025, 9, 1));
    expect(enricher.isAmountDateFallbackEnrichmentCandidate(sms, statement),
        isFalse);
  });

  test('does not match amount mismatch', () {
    final sms = tx(amount: 450.00);
    final statement = tx(amount: 451.00);
    expect(enricher.isStatementMatch(sms, statement), isFalse);
  });

  test('does not match timestamp outside tolerance', () {
    final sms = tx(timestamp: baseTime);
    final statement = tx(timestamp: baseTime.add(const Duration(minutes: 6)));
    expect(enricher.isStatementMatch(sms, statement), isFalse);
  });

  test('does not match opposite direction', () {
    final sms = tx(type: ParsedTransactionType.income);
    final statement = tx(type: ParsedTransactionType.expense);
    expect(enricher.isStatementMatch(sms, statement), isFalse);
  });

  test('enriches generic merchant', () {
    final sms = tx(merchant: 'UPI Transaction');
    final statement = tx(merchant: 'Sample Store');
    final result = enricher.enrichedMerchant(sms, statement);
    expect(result, 'Sample Store');
    expect(enricher.enrich(sms, statement), 'Sample Store');
  });

  test('does not overwrite specific existing merchant', () {
    final sms = tx(merchant: 'Specific Merchant');
    final statement = tx(merchant: 'Sample Store');
    expect(enricher.enrichedMerchant(sms, statement), isNull);
    expect(enricher.enrich(sms, statement), 'Specific Merchant');
  });

  test('does not use generic statement values', () {
    final sms = tx(merchant: 'Unknown Merchant');
    final statement = tx(merchant: 'UPI Transaction');
    expect(enricher.enrichedMerchant(sms, statement), isNull);
    expect(enricher.enrich(sms, statement), 'Unknown Merchant');
  });
}
