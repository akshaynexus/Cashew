// Service-level test: drives the real `runHistoricalSmsScan()` entry point
// (smsCaptureService.dart) against a fake inbox + real in-memory Drift DB.
// Unlike sms_capture_pipeline_test (which drove capture manually), this proves
// the SERVICE wires scan -> capture -> AUTO-enqueue of unrecognized.

import 'dart:convert';
import 'dart:io';

import 'package:budget/database/tables.dart';
import 'package:budget/functions.dart';
import 'package:budget/pages/addWalletPage.dart';
import 'package:budget/struct/databaseGlobal.dart';
import 'package:budget/struct/settings.dart';
import 'package:budget/struct/smsCaptureService.dart';
import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const String _channelName = 'cashew_pennywise/parser';

bool _smsMatches(Map golden, Map req) =>
    golden['sender'] == req['sender'] &&
    golden['body'] == req['body'] &&
    golden['timestamp'] == req['timestamp'];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late List<dynamic> goldens;

  setUp(() async {
    // The host is macOS; force the Android-only guard open for the test.
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
    await database.createOrUpdateCategory(
      insert: false,
      updateSharedEntry: false,
      TransactionCategory(
        categoryPk: "cat_income",
        name: "Income",
        colour: "0xff00ff00",
        iconName: null,
        dateCreated: DateTime.now(),
        dateTimeModified: null,
        order: 1,
        income: true,
      ),
    );
    await database.createOrUpdateCategory(
      insert: false,
      updateSharedEntry: false,
      TransactionCategory(
        categoryPk: "cat_food",
        name: "Food",
        colour: "0xffff0000",
        iconName: null,
        dateCreated: DateTime.now(),
        dateTimeModified: null,
        order: 2,
        income: false,
      ),
    );
    await database.createOrUpdateAssociatedTitle(
      TransactionAssociatedTitle(
        associatedTitlePk: "at_axis",
        categoryFk: "cat_income",
        title: "AXIS MUTUAL FUND REDEMPTION PO",
        dateCreated: DateTime.now(),
        dateTimeModified: null,
        order: 1,
        isExactMatch: false,
      ),
    );

    for (final w in [
      ["fallback", "Fallback", null, null],
      ["canara", "Canara", "Canara Bank", "9108"],
      ["hdfc", "HDFC", "HDFC Bank", "1234"],
    ]) {
      await database.createOrUpdateWallet(
        insert: false,
        TransactionWallet(
          walletPk: w[0]!,
          name: w[1]!,
          colour: null,
          iconName: null,
          dateCreated: DateTime.now(),
          dateTimeModified: null,
          order: 0,
          currency: "inr",
          decimals: 2,
          bankName: w[2],
          accountLast4: w[3],
        ),
      );
    }

    goldens = jsonDecode(await File(
            'packages/cashew_pennywise/test/fixtures/sms_parse_goldens.json')
        .readAsString()) as List<dynamic>;

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel(_channelName),
            (MethodCall call) async {
      switch (call.method) {
        case 'ping':
          return 42;
        case 'isKnownSender':
          // Every golden sender is a known bank sender (so the promo enqueues).
          return true;
        case 'readInbox':
          final since = (call.arguments as Map)['sinceEpochMillis'] as int?;
          final all = goldens
              .map((g) => Map<dynamic, dynamic>.from(g['sms'] as Map))
              .toList()
            ..sort((a, b) =>
                (a['timestamp'] as int).compareTo(b['timestamp'] as int));
          return all
              .where((m) => since == null || (m['timestamp'] as int) >= since)
              .toList();
        case 'parseBatch':
          final messages =
              ((call.arguments as Map)['messages'] as List).cast<Map>();
          final out = <Map<dynamic, dynamic>>[];
          for (final req in messages) {
            for (final g in goldens) {
              if (g['parsed'] == null) continue;
              if (_smsMatches(g['sms'] as Map, req)) {
                out.add(Map<dynamic, dynamic>.from(g['parsed'] as Map));
              }
            }
          }
          return out;
        default:
          return null;
      }
    });
  });

  tearDown(() {
    smsCaptureSupported = () => getPlatform() == PlatformOS.isAndroid;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel(_channelName), null);
  });

  test('runHistoricalSmsScan captures without fake balance corrections',
      () async {
    final summary = await runHistoricalSmsScan();

    // 5 unique parseable goldens captured (the exact-duplicate is collapsed by
    // the scanner before capture); the promo (parse==null, known sender) is
    // auto-enqueued by the service.
    expect(summary.inserted, 5, reason: summary.toString());
    expect(summary.unrecognized, 1, reason: summary.toString());

    // Rows landed in the DB with parsed provenance.
    final all = await database.allTransactions;
    final parsedRows =
        all.where((t) => t.methodAdded == MethodAdded.parsed).toList();
    expect(parsedRows.length, 5);
    expect(parsedRows.every((t) => t.transactionHash != null), true);

    // Reported SMS balance is metadata in PennyWise. Cashew has no equivalent
    // balance-history table yet, so capture must leave the ledger as real
    // transactions only.
    final canaraTotal =
        await database.watchTotalOfWalletNoConversion("canara").first;
    expect(canaraTotal, 1330614.75);
    final canaraTxns = await database.getAllTransactionsFromWallet("canara");
    expect(canaraTxns.where((t) => t.name == "balance-sync"), isEmpty);

    // The promo SMS is in the unrecognized review queue.
    final queue = await database.watchAllUnrecognizedSms().first;
    expect(queue.length, 1);
    expect(queue.first.sender, "AD-FEDBNK");
  });
}
