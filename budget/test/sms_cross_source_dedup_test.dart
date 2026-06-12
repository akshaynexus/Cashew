// Cross-source dedup: the same payment arriving via BOTH an SMS and a bank-app
// notification (different body text -> different transactionId) must insert
// once. A guard (same wallet OR same merchant) prevents merging two genuinely
// distinct same-amount transactions.

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
  String type = 'EXPENSE',
  bool isFromCard = false,
  required int tsMillis,
}) =>
    {
      'amount': amount,
      'type': type,
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
      'isFromCard': isFromCard,
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

  test('SMS then notification of the same payment captures once', () async {
    await _seed();
    final t = DateTime(2025, 5, 1, 12, 0).millisecondsSinceEpoch;

    // SMS: has last4 -> routes to the hdfc wallet.
    final sms = await captureParsedTransaction(ParsedTransaction.fromMap(_txn(
        id: "sms-hash",
        amount: "450.00",
        merchant: "Starbucks",
        last4: "1234",
        tsMillis: t)));
    expect(sms.outcome, CaptureOutcome.inserted);

    // Notification of the SAME payment 40s later: different id, no last4 (routes
    // to fallback wallet), same merchant + amount -> cross-source duplicate.
    final notif = await captureParsedTransaction(ParsedTransaction.fromMap(_txn(
        id: "notif-hash",
        amount: "450.00",
        merchant: "Starbucks",
        last4: null,
        tsMillis: t + 40000)));
    expect(notif.outcome, CaptureOutcome.duplicate);

    expect(_parsedCount(await database.allTransactions), 1);
  });

  test('two distinct same-amount payments are NOT merged', () async {
    await _seed();
    final t = DateTime(2025, 5, 1, 12, 0).millisecondsSinceEpoch;

    final a = await captureParsedTransaction(ParsedTransaction.fromMap(_txn(
        id: "a",
        amount: "450.00",
        merchant: "Starbucks",
        last4: "1234",
        tsMillis: t)));
    // Same wallet + amount + window but a DIFFERENT merchant -> real txn, keep.
    final b = await captureParsedTransaction(ParsedTransaction.fromMap(_txn(
        id: "b",
        amount: "450.00",
        merchant: "Dunkin",
        last4: "1234",
        tsMillis: t + 30000)));

    expect(a.outcome, CaptureOutcome.inserted);
    expect(b.outcome, CaptureOutcome.inserted);
    expect(_parsedCount(await database.allTransactions), 2);
  });

  test('same merchant and amount on different accounts is NOT merged',
      () async {
    await _seed();
    final t = DateTime(2025, 5, 1, 12, 0).millisecondsSinceEpoch;

    final a = await captureParsedTransaction(ParsedTransaction.fromMap(_txn(
        id: "same-merchant-a",
        amount: "450.00",
        merchant: "Starbucks",
        last4: "1234",
        tsMillis: t)));
    final b = await captureParsedTransaction(ParsedTransaction.fromMap(_txn(
        id: "same-merchant-b",
        amount: "450.00",
        merchant: "Starbucks",
        last4: "9876",
        tsMillis: t + 30000)));

    expect(a.outcome, CaptureOutcome.inserted);
    expect(b.outcome, CaptureOutcome.inserted);
    expect(_parsedCount(await database.allTransactions), 2);

    final second = await database.getTransactionByHash("same-merchant-b");
    expect(second, isNotNull);
    final secondWallet = await database.getWalletInstance(second!.walletFk);
    expect(secondWallet.accountLast4, "9876");
  });

  test('same UPI reference with different amount is NOT merged', () async {
    await _seed();
    final t = DateTime(2025, 5, 1, 12, 0).millisecondsSinceEpoch;

    final a = await captureParsedTransaction(ParsedTransaction.fromMap(_txn(
        id: "rrn-a",
        amount: "100.00",
        merchant: "UPI",
        last4: "1234",
        reference: "123456789012",
        tsMillis: t)));
    final b = await captureParsedTransaction(ParsedTransaction.fromMap(_txn(
        id: "rrn-b",
        amount: "200.00",
        merchant: "UPI",
        last4: "1234",
        reference: "123456789012",
        tsMillis: t + 30000)));

    expect(a.outcome, CaptureOutcome.inserted);
    expect(b.outcome, CaptureOutcome.inserted);
    expect(_parsedCount(await database.allTransactions), 2);
  });

  test('same amount + merchant but OUTSIDE the window is kept', () async {
    await _seed();
    final t = DateTime(2025, 5, 1, 12, 0).millisecondsSinceEpoch;

    final a = await captureParsedTransaction(ParsedTransaction.fromMap(_txn(
        id: "a",
        amount: "450.00",
        merchant: "Starbucks",
        last4: "1234",
        tsMillis: t)));
    // 5 minutes later -> beyond the ±2 min window -> a genuine second visit.
    final b = await captureParsedTransaction(ParsedTransaction.fromMap(_txn(
        id: "b",
        amount: "450.00",
        merchant: "Starbucks",
        last4: "1234",
        tsMillis: t + 5 * 60000)));

    expect(a.outcome, CaptureOutcome.inserted);
    expect(b.outcome, CaptureOutcome.inserted);
    expect(_parsedCount(await database.allTransactions), 2);
  });

  test('unseen account last4 creates a dedicated wallet instead of fallback',
      () async {
    await _seed();
    final t = DateTime(2026, 1, 1, 10).millisecondsSinceEpoch;

    final result = await captureParsedTransaction(ParsedTransaction.fromMap(
      _txn(
        id: "new-card",
        amount: "1200.00",
        merchant: "Amazon",
        last4: "9876",
        tsMillis: t,
      ),
    ));

    expect(result.outcome, CaptureOutcome.inserted);

    final inserted = await database.getTransactionByHash("new-card");
    expect(inserted, isNotNull);
    expect(inserted!.walletFk, isNot("fallback"));

    final wallet = await database.getWalletInstance(inserted.walletFk);
    expect(wallet.bankName, "HDFC Bank");
    expect(wallet.accountLast4, "9876");
    expect(wallet.name, contains("9876"));

    final fallbackTotal =
        await database.watchTotalOfWalletNoConversion("fallback").first;
    expect(fallbackTotal ?? 0, 0);
  });

  test('unseen card last4 creates a dedicated card wallet instead of fallback',
      () async {
    await _seed();
    final t = DateTime(2026, 1, 1, 10).millisecondsSinceEpoch;

    final result = await captureParsedTransaction(ParsedTransaction.fromMap(
      _txn(
        id: "new-card-wallet",
        amount: "2200.00",
        merchant: "Air India",
        last4: "6543",
        isFromCard: true,
        tsMillis: t,
      ),
    ));

    expect(result.outcome, CaptureOutcome.inserted);

    final inserted = await database.getTransactionByHash("new-card-wallet");
    expect(inserted, isNotNull);
    expect(inserted!.walletFk, isNot("fallback"));

    final wallet = await database.getWalletInstance(inserted.walletFk);
    expect(wallet.bankName, "HDFC Bank");
    expect(wallet.accountLast4, "6543");
    expect(wallet.name, contains("Card 6543"));
    expect(wallet.iconName, "credit-card.png");

    final fallbackTotal =
        await database.watchTotalOfWalletNoConversion("fallback").first;
    expect(fallbackTotal ?? 0, 0);
  });
}
