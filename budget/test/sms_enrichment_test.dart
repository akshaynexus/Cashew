// Reference-based enrichment: a generic "UPI" capture carrying a 12-digit UPI
// reference is later enriched by a GPay-PDF row with the SAME reference and the
// real merchant — upgrading the existing transaction's name with NO new row.

import 'package:budget/database/tables.dart';
import 'package:budget/struct/databaseGlobal.dart';
import 'package:budget/struct/settings.dart';
import 'package:budget/struct/transactionCapture.dart';
import 'package:cashew_pennywise/cashew_pennywise.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

Map<String, Object?> _txn({
  required String id,
  required String amount,
  required String merchant,
  String? last4,
  String? reference,
  required int tsMillis,
}) =>
    {
      'amount': amount,
      'type': 'EXPENSE',
      'merchant': merchant,
      'reference': reference,
      'accountLast4': last4,
      'balance': null,
      'creditLimit': null,
      'smsBody': '$merchant $amount $id',
      'sender': 'HDFCBK',
      'timestamp': tsMillis,
      'bankName': 'HDFC Bank',
      'transactionId': id,
      'isFromCard': false,
      'currency': 'INR',
      'fromAccount': null,
      'toAccount': null,
    };

int _parsedCount(List<Transaction> all) =>
    all.where((t) => t.methodAdded == MethodAdded.parsed).length;

Future<void> _seed() async {
  clientID = "test-client";
  SharedPreferences.setMockInitialValues({});
  sharedPreferences = await SharedPreferences.getInstance();
  appStateSettings = {
    "autoAddAssociatedTitles": true,
    "sharedBudgets": false,
    "selectedWalletPk": "fallback",
  };
  database = FinanceDatabase(NativeDatabase.memory());
  for (final w in [
    ["fallback", null, null],
    ["hdfc", "HDFC Bank", "1234"],
  ]) {
    await database.createOrUpdateWallet(
      insert: false,
      TransactionWallet(
        walletPk: w[0]!,
        name: w[0]!,
        colour: null,
        iconName: null,
        dateCreated: DateTime.now(),
        dateTimeModified: null,
        order: 0,
        currency: "inr",
        decimals: 2,
        bankName: w[1],
        accountLast4: w[2],
      ),
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const ref = "111222333444";

  test('generic UPI capture is enriched by same-reference statement', () async {
    await _seed();
    final t = DateTime(2025, 5, 1, 12, 0).millisecondsSinceEpoch;

    // SMS: generic merchant "UPI" + 12-digit reference -> routes to hdfc wallet.
    final sms = await captureParsedTransaction(ParsedTransaction.fromMap(_txn(
        id: "sms-hash",
        amount: "450.00",
        merchant: "UPI",
        last4: "1234",
        reference: ref,
        tsMillis: t)));
    expect(sms.outcome, CaptureOutcome.inserted);

    // GPay PDF: SAME reference, real merchant "Starbucks". Should enrich.
    final pdf = await captureParsedTransaction(ParsedTransaction.fromMap(_txn(
        id: "pdf-hash",
        amount: "450.00",
        merchant: "Starbucks",
        last4: "1234",
        reference: ref,
        tsMillis: t + 60000)));
    expect(pdf.outcome, CaptureOutcome.enriched);

    final all = await database.allTransactions;
    expect(_parsedCount(all), 1);
    final enriched =
        all.firstWhere((x) => x.methodAdded == MethodAdded.parsed);
    expect(enriched.name, "Starbucks");
  });

  test('same reference but existing already specific => duplicate, no enrich',
      () async {
    await _seed();
    final t = DateTime(2025, 5, 1, 12, 0).millisecondsSinceEpoch;

    final sms = await captureParsedTransaction(ParsedTransaction.fromMap(_txn(
        id: "sms-hash",
        amount: "450.00",
        merchant: "Starbucks",
        last4: "1234",
        reference: ref,
        tsMillis: t)));
    expect(sms.outcome, CaptureOutcome.inserted);

    final pdf = await captureParsedTransaction(ParsedTransaction.fromMap(_txn(
        id: "pdf-hash",
        amount: "450.00",
        merchant: "Some Other Name",
        last4: "1234",
        reference: ref,
        tsMillis: t + 60000)));
    expect(pdf.outcome, CaptureOutcome.duplicate);

    final all = await database.allTransactions;
    expect(_parsedCount(all), 1);
    final kept = all.firstWhere((x) => x.methodAdded == MethodAdded.parsed);
    expect(kept.name, "Starbucks");
  });
}
