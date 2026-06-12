// Mandate / subscription capture: a mandate-setup SMS (which does NOT parse as
// a transaction) is detected via parseMandate and turned into a Cashew recurring
// subscription transaction. Tests captureMandate directly and through the
// service's scan path. Cashew-only, real in-memory Drift DB.

import 'package:budget/database/tables.dart';
import 'package:budget/functions.dart';
import 'package:budget/pages/addWalletPage.dart';
import 'package:budget/struct/databaseGlobal.dart';
import 'package:budget/struct/settings.dart';
import 'package:budget/struct/smsCaptureService.dart';
import 'package:budget/struct/transactionCapture.dart';
import 'package:cashew_pennywise/cashew_pennywise.dart';
import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const String _channelName = 'cashew_pennywise/parser';

const _mandateSms = {
  'sender': 'AD-FEDBNK',
  'body':
      'E-mandate! Rs.59.00 will be deducted on 29-May-25 towards Netflix from '
          'A/c XX1234. UMN:abc123de@okhdfcbank -Federal Bank',
  'timestamp': 1748476800000,
};

// The map the plugin bridge would return for the mandate SMS above.
final _mandateMap = {
  'amount': '59.00',
  'merchant': 'Netflix',
  'umn': 'abc123de@okhdfcbank',
  'nextDeductionDate': '29-May-25',
  'nextDeductionEpochMillis': DateTime(2025, 5, 29).millisecondsSinceEpoch,
  'bankName': 'Federal Bank',
  'sender': 'AD-FEDBNK',
  'smsBody': _mandateSms['body'],
};

Future<void> _seed() async {
  smsCaptureSupported = () => true;
  clientID = "test-client";
  SharedPreferences.setMockInitialValues({});
  sharedPreferences = await SharedPreferences.getInstance();
  appStateSettings = {
    "autoAddAssociatedTitles": true,
    "sharedBudgets": false,
    "selectedWalletPk": "fallback",
  };
  database = FinanceDatabase(NativeDatabase.memory());
  await initializeBalanceCorrectionCategory();
  await database.createOrUpdateWallet(
    insert: false,
    TransactionWallet(
      walletPk: "fallback",
      name: "Fallback",
      colour: null,
      iconName: null,
      dateCreated: DateTime.now(),
      dateTimeModified: null,
      order: 0,
      currency: "inr",
      decimals: 2,
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    smsCaptureSupported = () => getPlatform() == PlatformOS.isAndroid;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel(_channelName), null);
  });

  test('captureMandate creates a monthly subscription, then dedups', () async {
    await _seed();
    final mandate = ParsedMandate.fromMap(_mandateMap);

    expect(await captureMandate(mandate), MandateCaptureOutcome.created);

    final subs = (await database.allTransactions)
        .where((t) => t.type == TransactionSpecialType.subscription)
        .toList();
    expect(subs.length, 1);
    final sub = subs.first;
    expect(sub.name, "Netflix");
    expect(sub.amount, -59.0); // recurring expense
    expect(sub.reoccurrence, BudgetReoccurence.monthly);
    expect(sub.periodLength, 1);
    expect(sub.methodAdded, MethodAdded.parsed);
    expect(sub.transactionHash, "mandate:abc123de@okhdfcbank");
    // Cashew nudges dateCreated by a few seconds for ordering; assert the date.
    expect(sub.dateCreated.year, 2025);
    expect(sub.dateCreated.month, 5);
    expect(sub.dateCreated.day, 29);

    // Re-capturing the same mandate does not create a second subscription.
    expect(await captureMandate(mandate), MandateCaptureOutcome.duplicate);
    expect(
      (await database.allTransactions)
          .where((t) => t.type == TransactionSpecialType.subscription)
          .length,
      1,
    );
  });

  test('runHistoricalSmsScan detects a mandate SMS as a subscription', () async {
    await _seed();

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel(_channelName),
            (MethodCall call) async {
      switch (call.method) {
        case 'isKnownSender':
          return true;
        case 'readInbox':
          return [Map<dynamic, dynamic>.from(_mandateSms)];
        case 'parseBatch':
          return <Map>[]; // the mandate SMS is not a transaction
        case 'parseMandate':
          return Map<dynamic, dynamic>.from(_mandateMap);
        default:
          return null;
      }
    });

    final summary = await runHistoricalSmsScan();
    expect(summary.subscriptions, 1, reason: summary.toString());
    expect(summary.unrecognized, 0, reason: 'mandate is not queued as unknown');

    final subs = (await database.allTransactions)
        .where((t) => t.type == TransactionSpecialType.subscription)
        .toList();
    expect(subs.length, 1);
    expect(subs.first.name, "Netflix");
  });
}
