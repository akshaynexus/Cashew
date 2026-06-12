// Transaction-capture orchestrator.
//
// Turns a parser-produced [ParsedTransaction] (from the cashew_pennywise SMS /
// PDF parsers) into a Cashew [Transaction], with:
//  - hash-based deduplication (skip if we already captured this message),
//  - account routing by (bankName, accountLast4) -> Wallet, and
//  - optional bank-balance reconciliation via a balance-correction transaction.
//
// This is the single glue point between the plugin's pure parsing/decision
// logic and Cashew's Drift database. The pure dedup/reconcile rules live in the
// plugin (CaptureDeduplicator / BalanceReconciler); this file only wires them
// to the global `database` and Cashew's insert/correction primitives.

import 'package:budget/database/tables.dart';
import 'package:budget/pages/addTransactionPage.dart';
import 'package:budget/pages/addWalletPage.dart';
import 'package:budget/struct/databaseGlobal.dart';
import 'package:budget/struct/settings.dart';
import 'package:cashew_pennywise/src/capture/balance_reconciler.dart';
import 'package:cashew_pennywise/src/parsed_transaction.dart';

/// What happened when a parsed transaction was handed to [captureParsedTransaction].
enum CaptureOutcome {
  /// A new Cashew transaction was inserted.
  inserted,

  /// Skipped: a transaction with the same hash already exists.
  duplicate,

  /// Skipped: no wallet and no fallback wallet, or no category could be
  /// resolved, so nothing was inserted.
  unmapped,
}

/// Result of a capture attempt.
class TransactionCaptureResult {
  final CaptureOutcome outcome;

  /// The primary key of the inserted transaction, if one was created.
  final String? transactionPk;

  /// The primary key of the balance-correction transaction, if reconciliation
  /// produced one.
  final String? correctionTransactionPk;

  const TransactionCaptureResult({
    required this.outcome,
    this.transactionPk,
    this.correctionTransactionPk,
  });

  bool get wasInserted => outcome == CaptureOutcome.inserted;

  @override
  String toString() => 'TransactionCaptureResult($outcome, '
      'transactionPk=$transactionPk, '
      'correctionTransactionPk=$correctionTransactionPk)';
}

/// Note marker stamped on auto-reconcile balance corrections so a later
/// reconcile can find and replace the previous one (avoiding correction spam).
const String kReconcileMarker = "[auto-balance-sync]";

const BalanceReconciler _reconciler = BalanceReconciler();

/// Captures a [parsed] bank transaction into Cashew.
///
/// Steps:
///  1. Dedup by hash: if `getTransactionByHash(parsed.transactionId)` returns
///     non-null, do nothing and return a [CaptureOutcome.duplicate] result.
///  2. Resolve the wallet by (bankName, accountLast4); fall back to the app's
///     `selectedWalletPk` if there is no match.
///  3. Resolve a category from the merchant via similar associated titles; fall
///     back to the default/uncategorized category.
///  4. Insert a [Transaction] (`methodAdded: MethodAdded.parsed`).
///  5. If [reconcileBalance] and the message reported a balance AND the wallet
///     was matched by last4, reconcile the wallet's running balance.
Future<TransactionCaptureResult> captureParsedTransaction(
  ParsedTransaction parsed, {
  bool reconcileBalance = true,
}) async {
  // 1. Dedup by stable hash.
  if (parsed.transactionId.isNotEmpty) {
    final existing = await database.getTransactionByHash(parsed.transactionId);
    if (existing != null) {
      return const TransactionCaptureResult(outcome: CaptureOutcome.duplicate);
    }
  }

  // 2. Resolve the wallet. matchedByLast4 gates reconciliation: we only trust
  //    a reported balance against a wallet we actually identified by account.
  TransactionWallet? wallet;
  bool matchedByLast4 = false;
  final last4 = parsed.accountLast4;
  if (last4 != null && last4.isNotEmpty) {
    wallet = await database.getWalletByBankAndLast4(parsed.bankName, last4);
    matchedByLast4 = wallet != null;
  }
  if (wallet == null) {
    final fallbackPk = appStateSettings["selectedWalletPk"];
    if (fallbackPk is String) {
      wallet = await database.getWalletInstanceOrNull(fallbackPk);
    }
  }
  if (wallet == null) {
    return const TransactionCaptureResult(outcome: CaptureOutcome.unmapped);
  }

  // 3. Resolve a category from the merchant; else fall back to default ("0").
  final String? merchant = parsed.merchant;
  TransactionCategory? category;
  if (merchant != null && merchant.isNotEmpty) {
    final foundTitle =
        (await database.getSimilarAssociatedTitles(title: merchant, limit: 1))
            .firstOrNull;
    category = foundTitle?.category;
    if (category != null) {
      // Mirror the email flow: learn this merchant -> category association.
      await addAssociatedTitles(merchant, category);
    }
  }
  category ??= await _defaultCategory();
  if (category == null) {
    return const TransactionCaptureResult(outcome: CaptureOutcome.unmapped);
  }

  // 4. Build + insert the transaction.
  //    Sign convention mirrors autoTransactionsPageEmail: amount magnitude is
  //    signed by the chosen category's income flag. parsed.signedAmount already
  //    encodes the parser's direction; we honor the category flag for the sign
  //    (so a category marked income makes this an inflow) but keep the parser's
  //    magnitude.
  final double magnitude = parsed.signedAmount.abs();
  final double amount = magnitude * (category.income ? 1 : -1);

  final String name = (merchant != null && merchant.isNotEmpty)
      ? merchant
      : parsed.bankName;

  final int? rowId = await database.createOrUpdateTransaction(
    insert: true,
    Transaction(
      transactionPk: "-1",
      name: name,
      amount: amount,
      note: "",
      categoryFk: category.categoryPk,
      walletFk: wallet.walletPk,
      dateCreated: parsed.timestamp,
      dateTimeModified: null,
      income: category.income,
      paid: true,
      skipPaid: false,
      methodAdded: MethodAdded.parsed,
      transactionHash:
          parsed.transactionId.isNotEmpty ? parsed.transactionId : null,
    ),
  );

  String? insertedPk;
  if (rowId != null) {
    final inserted = await database.getTransactionFromRowId(rowId);
    insertedPk = inserted.transactionPk;
  }

  // 5. Reconcile the bank-reported balance, if we trust the routing.
  String? correctionPk;
  if (reconcileBalance && matchedByLast4 && parsed.balance != null) {
    correctionPk = await _reconcileWalletBalance(wallet, parsed);
  }

  return TransactionCaptureResult(
    outcome: CaptureOutcome.inserted,
    transactionPk: insertedPk,
    correctionTransactionPk: correctionPk,
  );
}

/// Reconciles [wallet]'s current Cashew balance against the bank-reported
/// balance carried by [parsed], creating/replacing a balance-correction
/// transaction if they drift beyond tolerance.
///
/// Correction-spam handling: each auto-reconcile correction is tagged with
/// [kReconcileMarker] in its note. Before creating a new one we delete the most
/// recent existing marked correction for this wallet, so the wallet carries at
/// most one standing auto-sync correction rather than accumulating one per SMS.
Future<String?> _reconcileWalletBalance(
  TransactionWallet wallet,
  ParsedTransaction parsed,
) async {
  final reported = double.tryParse(parsed.balance ?? "");
  if (reported == null) return null;

  // Reuse Cashew's existing wallet-balance query (the same SUM used across the
  // app for a wallet total): watchTotalOfWalletNoConversion. We take its
  // current value via .first.
  final double computed =
      (await database.watchTotalOfWalletNoConversion(wallet.walletPk).first) ??
          0.0;

  final result = _reconciler.reconcile(
    reportedBalance: reported,
    computedBalance: computed,
    type: parsed.type,
    isFromCard: parsed.isFromCard,
    decimals: wallet.decimals,
  );

  if (!result.needsCorrection) return null;

  // Remove the previous auto-sync correction (if any) before adding a fresh
  // one, so corrections don't stack.
  await _deletePreviousReconcileCorrections(wallet.walletPk);

  return await createCorrectionTransaction(
    result.correctionDelta,
    wallet,
    title: "balance-sync",
    note: kReconcileMarker,
    dateTime: parsed.timestamp,
  );
}

/// Deletes prior auto-reconcile balance corrections for [walletPk] (those in
/// the balance-correction category "0" whose note carries [kReconcileMarker]).
Future<void> _deletePreviousReconcileCorrections(String walletPk) async {
  final all = await database.getAllTransactionsFromWallet(walletPk);
  for (final t in all) {
    if (t.categoryFk == "0" && (t.note).contains(kReconcileMarker)) {
      await database.deleteTransaction(t.transactionPk);
    }
  }
}

/// The default / uncategorized category (pk "0"), creating it if missing.
/// Reuses the wallet page's `initializeBalanceCorrectionCategory`, which is the
/// canonical "ensure category 0 exists" primitive in Cashew. Returns null only
/// if that fails unexpectedly, in which case the capture is reported unmapped.
Future<TransactionCategory?> _defaultCategory() async {
  try {
    return await initializeBalanceCorrectionCategory();
  } catch (_) {
    return null;
  }
}

/// What happened when a [ParsedMandate] was handed to [captureMandate].
enum MandateCaptureOutcome { created, duplicate, unmapped }

/// Turns a detected e-mandate / subscription into a Cashew **recurring
/// (subscription) transaction**, reusing the existing repeating-transaction
/// engine (`TransactionSpecialType.subscription`) rather than a parallel table.
///
/// Dedup is by the mandate's stable id (UMN when available) stored in
/// `transactionHash`, so re-seeing the same mandate SMS does not create a
/// duplicate subscription. Mandates are autopay debits, so they are recorded as
/// monthly expenses dated to the next deduction.
Future<MandateCaptureOutcome> captureMandate(ParsedMandate mandate) async {
  final String hash = mandate.mandateId;
  if (await database.getTransactionByHash(hash) != null) {
    return MandateCaptureOutcome.duplicate;
  }

  // Mandates rarely carry an account number — route to the selected wallet.
  TransactionWallet? wallet;
  final fallbackPk = appStateSettings["selectedWalletPk"];
  if (fallbackPk is String) {
    wallet = await database.getWalletInstanceOrNull(fallbackPk);
  }
  if (wallet == null) return MandateCaptureOutcome.unmapped;

  TransactionCategory? category;
  if (mandate.merchant.isNotEmpty) {
    category = (await database.getSimilarAssociatedTitles(
            title: mandate.merchant, limit: 1))
        .firstOrNull
        ?.category;
  }
  category ??= await _defaultCategory();
  if (category == null) return MandateCaptureOutcome.unmapped;

  final double magnitude = (double.tryParse(mandate.amount) ?? 0).abs();

  await database.createOrUpdateTransaction(
    insert: true,
    Transaction(
      transactionPk: "-1",
      name: mandate.merchant,
      amount: -magnitude, // recurring autopay = expense
      note: "",
      categoryFk: category.categoryPk,
      walletFk: wallet.walletPk,
      dateCreated: mandate.nextDeductionDate ?? DateTime.now(),
      dateTimeModified: null,
      income: false,
      paid: false, // upcoming
      skipPaid: false,
      type: TransactionSpecialType.subscription,
      reoccurrence: BudgetReoccurence.monthly,
      periodLength: 1,
      methodAdded: MethodAdded.parsed,
      transactionHash: hash,
    ),
  );
  return MandateCaptureOutcome.created;
}

/// Queues an SMS whose sender is a known bank but whose body the parser could
/// not turn into a transaction, for later manual review. The viewing UI is
/// owned by another module; this only writes the row.
Future<void> enqueueUnrecognized(String sender, String body) async {
  await database.createOrUpdateUnrecognizedSms(
    UnrecognizedSm(
      unrecognizedSmsPk: "-1",
      sender: sender,
      body: body,
      dateCreated: DateTime.now(),
      handled: false,
    ),
    insert: true,
  );
}
