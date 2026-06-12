// End-to-end integration test for the SMS-capture pipeline.
//
// Fake SMS inbox (MethodChannel) -> SmsScanner (fetch + parse) ->
// captureParsedTransaction() -> rows inserted into a REAL in-memory
// FinanceDatabase. Asserts row insertion, dedup, account routing,
// merchant->category, MethodAdded.parsed + transactionHash, and that reported
// SMS balances do not create fake ledger corrections.
//
// Run from `budget/`:  flutter test test/sms_capture_pipeline_test.dart

import 'dart:convert';
import 'dart:io';

import 'package:budget/database/tables.dart';
import 'package:budget/pages/addWalletPage.dart';
import 'package:budget/struct/databaseGlobal.dart';
import 'package:budget/struct/settings.dart';
import 'package:budget/struct/transactionCapture.dart';
import 'package:cashew_pennywise/src/parsed_transaction.dart';
import 'package:cashew_pennywise/src/sms_scanner.dart';
import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const String _channelName = 'cashew_pennywise/parser';

/// Match a parseBatch `messages` entry against a golden `sms` map.
bool _smsMatches(Map golden, Map req) =>
    golden['sender'] == req['sender'] &&
    golden['body'] == req['body'] &&
    golden['timestamp'] == req['timestamp'];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late List<dynamic> goldens;

  setUp(() async {
    // --- Globals the capture path reads ---
    clientID = "test-client";
    SharedPreferences.setMockInitialValues({});
    sharedPreferences = await SharedPreferences.getInstance();
    // appStateSettings drives sign-by-category-flag learning, sharedBudgets
    // gating in createOrUpdate*, and the fallback wallet pk.
    appStateSettings = {
      "autoAddAssociatedTitles": true,
      "sharedBudgets": false,
      "selectedWalletPk": "fallback",
    };

    // --- Real in-memory Drift database ---
    database = FinanceDatabase(NativeDatabase.memory());

    // --- Seed categories ---
    // Default/uncategorized category ("0") used by Cashew for manual balance
    // corrections. SMS capture must not create those rows automatically.
    await initializeBalanceCorrectionCategory();
    // An income category so the Canara INCOME credit is signed positive.
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
    // An expense category for merchant routing (Swiggy -> Food).
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

    // --- Seed associated titles so merchants route to categories ---
    await database.createOrUpdateAssociatedTitle(
      TransactionAssociatedTitle(
        associatedTitlePk: "at_swiggy",
        categoryFk: "cat_food",
        title: "Swiggy",
        dateCreated: DateTime.now(),
        dateTimeModified: null,
        order: 0,
        isExactMatch: false,
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

    // --- Seed wallets ---
    // Fallback wallet whose pk == selectedWalletPk.
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
    // Canara wallet mapped by (bankName, accountLast4).
    // Give it a known starting state (a single +100 transaction) so we can
    // prove SMS reported balances do not fabricate a correction.
    await database.createOrUpdateWallet(
      insert: false,
      TransactionWallet(
        walletPk: "canara",
        name: "Canara",
        colour: null,
        iconName: null,
        dateCreated: DateTime.now(),
        dateTimeModified: null,
        order: 1,
        currency: "inr",
        decimals: 2,
        bankName: "Canara Bank",
        accountLast4: "9108",
      ),
    );
    // HDFC wallet mapped by last4 1234.
    await database.createOrUpdateWallet(
      insert: false,
      TransactionWallet(
        walletPk: "hdfc",
        name: "HDFC",
        colour: null,
        iconName: null,
        dateCreated: DateTime.now(),
        dateTimeModified: null,
        order: 2,
        currency: "inr",
        decimals: 2,
        bankName: "HDFC Bank",
        accountLast4: "1234",
      ),
    );
    // Known starting state for Canara wallet: +100.
    await database.createOrUpdateTransaction(
      insert: true,
      updateSharedEntry: false,
      Transaction(
        transactionPk: "-1",
        name: "seed",
        amount: 100.0,
        note: "",
        categoryFk: "cat_income",
        walletFk: "canara",
        dateCreated: DateTime(2025, 1, 1),
        income: true,
        paid: true,
        skipPaid: false,
      ),
    );

    // --- Load goldens ---
    final file =
        File('packages/cashew_pennywise/test/fixtures/sms_parse_goldens.json');
    goldens = jsonDecode(await file.readAsString()) as List<dynamic>;

    // --- Fake the MethodChannel ---
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel(_channelName),
            (MethodCall call) async {
      switch (call.method) {
        case 'ping':
          return 42;
        case 'hasSmsPermissions':
        case 'requestSmsPermissions':
          return true;
        case 'readInbox':
          final args = call.arguments as Map;
          final since = args['sinceEpochMillis'] as int?;
          // Return all golden `sms` maps with timestamp >= since (ascending).
          final all = goldens
              .map((g) => Map<dynamic, dynamic>.from(g['sms'] as Map))
              .toList()
            ..sort((a, b) =>
                (a['timestamp'] as int).compareTo(b['timestamp'] as int));
          return all
              .where((m) => since == null || (m['timestamp'] as int) >= since)
              .toList();
        case 'parseBatch':
          final args = call.arguments as Map;
          final messages = (args['messages'] as List).cast<Map>();
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
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel(_channelName), null);
  });

  test('full SMS capture pipeline against real in-memory Drift DB', () async {
    // --- Run the real fetch+parse pipeline ---
    final scanner = SmsScanner();
    final discovered = <ParsedTransaction>[];
    await for (final progress in scanner.scanInbox(pageSize: 500)) {
      discovered.addAll(progress.newTransactions);
    }

    // The scanner's within-scan dedup collapses the exact-duplicate Federal
    // debit, so 5 unique parseable transactions are discovered (the promo is
    // null and never reaches parseBatch output).
    expect(discovered.length, 5,
        reason: 'scanner should yield 5 unique parseable txns');

    // --- Capture each through the real orchestrator -> real DB inserts ---
    final results = <TransactionCaptureResult>[];
    for (final pt in discovered) {
      results.add(await captureParsedTransaction(pt));
    }

    // All 5 inserted.
    expect(
        results.where((r) => r.outcome == CaptureOutcome.inserted).length, 5);

    // ---- Assertion 1: rows inserted with parsed metadata ----
    final all = await database.allTransactions;
    // 5 captured + 1 seed = 6. Reported SMS balances must not add rows.
    final parsedRows =
        all.where((t) => t.methodAdded == MethodAdded.parsed).toList();
    expect(parsedRows.length, 5);
    for (final t in parsedRows) {
      expect(t.transactionHash, isNotNull);
    }

    final swiggy = parsedRows.firstWhere((t) => t.name == "Swiggy");
    expect(swiggy.transactionHash, "03732458b631a7b501e2beb8a0e389cf");
    expect(swiggy.amount, -450.75); // expense category -> negative
    expect(swiggy.categoryFk, "cat_food");

    final indigo = parsedRows.firstWhere((t) => t.name == "Indigo");
    expect(indigo.transactionHash, "f8391bc7aaba719f968a11377c9ccfe5");
    expect(indigo.amount, -3500.00);

    final canara = parsedRows.firstWhere(
        (t) => t.transactionHash == "e6f505362c060f1203c3436711c3ce01");
    expect(canara.income, true);
    expect(canara.amount, 1330614.75); // income category -> positive
    expect(canara.categoryFk, "cat_income");

    // ---- Assertion 2: dedup ----
    final countBefore = (await database.allTransactions).length;
    // Capture the exact-duplicate Federal debit golden again.
    final dupGolden = goldens.last['parsed'] as Map;
    final dupResult = await captureParsedTransaction(
        ParsedTransaction.fromMap(Map<dynamic, dynamic>.from(dupGolden)));
    expect(dupResult.outcome, CaptureOutcome.duplicate);
    final countAfter = (await database.allTransactions).length;
    expect(countAfter, countBefore, reason: 'no new row for duplicate');
    expect(
        await database.getTransactionByHash("e508ac7ddbb33a86bdcf009afb2bbc66"),
        isNotNull);

    // ---- Assertion 3: account routing ----
    expect(canara.walletFk, "canara", reason: 'Canara routed by last4 9108');
    final hdfc = parsedRows.firstWhere(
        (t) => t.transactionHash == "2faa2408d04b0440ac4d435b803f1aaa");
    expect(hdfc.walletFk, "hdfc", reason: 'HDFC routed by last4 1234');
    // Federal debits (no last4) fall back to selectedWalletPk.
    final federalSwiggy = swiggy;
    expect(federalSwiggy.walletFk, "fallback",
        reason: 'Federal (no last4) routes to fallback wallet');

    // ---- Assertion 4: reported SMS balances do not mutate the ledger ----
    final canaraTotal =
        await database.watchTotalOfWalletNoConversion("canara").first;
    expect(canaraTotal, 1330714.75,
        reason:
            'Canara total is seed + real parsed transaction, not reported balance');
    final canaraTxns = await database.getAllTransactionsFromWallet("canara");
    final corrections =
        canaraTxns.where((t) => t.name == "balance-sync").toList();
    expect(corrections, isEmpty,
        reason: 'SMS capture must not create balance-sync corrections');

    // ---- Assertion 5: unrecognized queue ----
    // The promo (parsed == null, known sender) is NOT auto-enqueued by the
    // scanner/capture path (the scanner is persistence-free and only yields
    // parsed transactions; null results never surface). We drive
    // enqueueUnrecognized() directly, matching how a host would handle it.
    final promo = goldens.firstWhere((g) => g['parsed'] == null);
    final promoSms = promo['sms'] as Map;
    await enqueueUnrecognized(
        promoSms['sender'] as String, promoSms['body'] as String);
    final unrecognized = await database.watchAllUnrecognizedSms().first;
    expect(unrecognized.length, 1);
    expect(unrecognized.first.sender, "AD-FEDBNK");
    expect(unrecognized.first.handled, false);
  });
}
