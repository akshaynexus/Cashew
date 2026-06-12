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
  String bankName = 'HDFC Bank',
  String currency = 'INR',
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
      'bankName': bankName,
      'transactionId': id,
      'isFromCard': isFromCard,
      'currency': currency,
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
    "cachedCurrencyExchange": {
      "aed": 3.67,
      "inr": 83.0,
      "thb": 36.0,
      "usd": 1.0,
    },
    "customCurrencyAmounts": {},
  };
  database = FinanceDatabase(NativeDatabase.memory());
  for (final w in [
    ["fallback", null, null, "inr"],
    ["hdfc", "HDFC Bank", "1234", "inr"],
    ["fab", "First Abu Dhabi Bank", "7777", "aed"],
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
        currency: w[3],
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

  test('unmapped income stays positive instead of using expense category sign',
      () async {
    await _seed();
    final t = DateTime(2026, 1, 1, 10).millisecondsSinceEpoch;

    final result = await captureParsedTransaction(ParsedTransaction.fromMap(
      _txn(
        id: "refund-income",
        amount: "500.00",
        merchant: "Refund",
        last4: "1234",
        type: "INCOME",
        tsMillis: t,
      ),
    ));

    expect(result.outcome, CaptureOutcome.inserted);

    final inserted = await database.getTransactionByHash("refund-income");
    expect(inserted, isNotNull);
    expect(inserted!.amount, 500);
    expect(inserted.income, isTrue);
    expect(inserted.walletFk, "hdfc");

    final hdfcTotal =
        await database.watchTotalOfWalletNoConversion("hdfc").first;
    expect(hdfcTotal, 500);
  });

  test('balance update messages are not inserted as ledger transactions',
      () async {
    await _seed();
    final t = DateTime(2026, 1, 1, 10).millisecondsSinceEpoch;

    final result = await captureParsedTransaction(ParsedTransaction.fromMap(
      _txn(
        id: "balance-update",
        amount: "12000.00",
        merchant: "Available balance",
        last4: "1234",
        type: "BALANCE_UPDATE",
        tsMillis: t,
      ),
    ));

    expect(result.outcome, CaptureOutcome.unmapped);
    expect(await database.getTransactionByHash("balance-update"), isNull);
    expect(_parsedCount(await database.allTransactions), 0);
  });

  test(
      'foreign-currency card spend keeps original currency and books wallet amount',
      () async {
    await _seed();
    final t = DateTime(2026, 1, 1, 10).millisecondsSinceEpoch;

    final result = await captureParsedTransaction(ParsedTransaction.fromMap(
      _txn(
        id: "fab-thb",
        amount: "360.00",
        merchant: "Bangkok Hotel",
        last4: "7777",
        bankName: "First Abu Dhabi Bank",
        currency: "THB",
        isFromCard: true,
        tsMillis: t,
      ),
    ));

    expect(result.outcome, CaptureOutcome.inserted);

    final inserted = await database.getTransactionByHash("fab-thb");
    expect(inserted, isNotNull);
    expect(inserted!.walletFk, "fab");
    expect(inserted.originalAmount, -360);
    expect(inserted.originalCurrency, "thb");
    expect(inserted.originalToWalletExchangeRate, closeTo(3.67 / 36.0, 0.0001));
    expect(inserted.amount, closeTo(-36.7, 0.001));

    final fabTotal = await database.watchTotalOfWalletNoConversion("fab").first;
    expect(fabTotal, closeTo(-36.7, 0.001));
  });

  test('unseen FAB foreign-currency card creates AED wallet', () async {
    await _seed();
    final t = DateTime(2026, 1, 1, 10).millisecondsSinceEpoch;

    final result = await captureParsedTransaction(ParsedTransaction.fromMap(
      _txn(
        id: "fab-usd-new-card",
        amount: "10.00",
        merchant: "US Store",
        last4: "8888",
        bankName: "First Abu Dhabi Bank",
        currency: "USD",
        isFromCard: true,
        tsMillis: t,
      ),
    ));

    expect(result.outcome, CaptureOutcome.inserted);

    final inserted = await database.getTransactionByHash("fab-usd-new-card");
    expect(inserted, isNotNull);
    expect(inserted!.originalAmount, -10);
    expect(inserted.originalCurrency, "usd");
    expect(inserted.amount, closeTo(-36.7, 0.001));

    final wallet = await database.getWalletInstance(inserted.walletFk);
    expect(wallet.bankName, "First Abu Dhabi Bank");
    expect(wallet.accountLast4, "8888");
    expect(wallet.currency, "aed");
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
