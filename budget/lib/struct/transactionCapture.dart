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

import 'package:budget/colors.dart';
import 'package:budget/database/tables.dart';
import 'package:budget/pages/addTransactionPage.dart';
import 'package:budget/pages/addWalletPage.dart';
import 'package:budget/struct/databaseGlobal.dart';
import 'package:budget/struct/settings.dart';
import 'package:cashew_pennywise/src/capture/balance_reconciler.dart';
import 'package:cashew_pennywise/src/capture/transaction_enricher.dart';
import 'package:cashew_pennywise/src/parsed_transaction.dart';
import 'package:flutter/material.dart';

/// What happened when a parsed transaction was handed to [captureParsedTransaction].
enum CaptureOutcome {
  /// A new Cashew transaction was inserted.
  inserted,

  /// Skipped: a transaction with the same hash already exists.
  duplicate,

  /// Skipped: no wallet and no fallback wallet, or no category could be
  /// resolved, so nothing was inserted.
  unmapped,

  /// An existing transaction's merchant name was upgraded from the incoming
  /// (e.g. a GPay PDF row carrying the real merchant for an SMS-captured "UPI"
  /// payment). No new row was inserted.
  enriched,
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

/// Window for cross-source (SMS vs notification) duplicate matching, mirroring
/// PennyWise's ±2-minute amount+bank match in its native notification listener.
const Duration kCrossSourceWindow = Duration(minutes: 2);

/// True if [parsed] looks like the same payment as an already-captured
/// transaction arriving via the other channel (SMS↔notification): same
/// magnitude AND same merchant within [kCrossSourceWindow].
///
/// We key on merchant (not wallet): a notification often lacks the account
/// number and routes to a different wallet than the SMS, and matching on
/// wallet+amount alone would wrongly merge two distinct same-amount payments
/// to the same account. Merchant+amount+window is the reliable shared signal.
Future<bool> _isCrossSourceDuplicate(ParsedTransaction parsed) async {
  final double magnitude = parsed.signedAmount.abs();
  final String merchant = (parsed.merchant ?? "").trim().toLowerCase();
  if (magnitude <= 0 || merchant.isEmpty) return false;

  final near = await database.getCapturedTransactionsInRange(
    parsed.timestamp.subtract(kCrossSourceWindow),
    parsed.timestamp.add(kCrossSourceWindow),
  );

  for (final t in near) {
    if ((t.amount.abs() - magnitude).abs() > 0.001) continue;
    if (t.name.trim().toLowerCase() == merchant) return true;
  }
  return false;
}

const BalanceReconciler _reconciler = BalanceReconciler();
const TransactionEnricher _enricher = TransactionEnricher();

/// Matches a 12-digit UPI RRN — the reference key used for reference-based
/// enrichment (a PDF statement row and the original SMS share this).
final RegExp _upiReferencePattern = RegExp(r'^\d{12}$');

/// Maps the incoming [parsed] transaction to a statement [EnrichCandidate].
EnrichCandidate _statementCandidate(ParsedTransaction parsed) => EnrichCandidate(
      amount: parsed.signedAmount.abs(),
      currency: parsed.currency,
      type: parsed.type,
      reference: parsed.reference,
      merchant: parsed.merchant,
      accountLast4: parsed.accountLast4,
      timestamp: parsed.timestamp,
    );

/// Maps an already-captured Cashew [existing] transaction to an [EnrichCandidate].
/// Looks up the existing transaction's wallet to recover its account last4.
Future<EnrichCandidate> _existingCandidate(
  Transaction existing,
  ParsedTransaction parsed,
) async {
  final wallet = await database.getWalletInstanceOrNull(existing.walletFk);
  return EnrichCandidate(
    amount: existing.amount.abs(),
    // Cashew stores a single per-wallet currency; reconcile against the
    // incoming currency so the comparison isn't tripped by an unknown existing
    // currency. The reference/account match already anchors identity.
    currency: parsed.currency,
    type: existing.income
        ? ParsedTransactionType.income
        : ParsedTransactionType.expense,
    reference: existing.parsedReference,
    merchant: existing.name,
    accountLast4: wallet?.accountLast4,
    timestamp: existing.dateCreated,
  );
}

/// Updates [existing]'s merchant name to [newName], preserving its primary key.
Future<void> _updateMerchant(Transaction existing, String newName) async {
  await database.createOrUpdateTransaction(
    insert: false,
    existing.copyWith(name: newName),
  );
}

/// Reference-based enrichment/dedup. If [parsed] carries a 12-digit UPI ref that
/// already maps to a captured transaction, either enrich that transaction's
/// merchant (returning [CaptureOutcome.enriched]) or treat it as a duplicate
/// ([CaptureOutcome.duplicate]). Returns null if no reference match applies.
Future<CaptureOutcome?> _tryReferenceEnrichment(ParsedTransaction parsed) async {
  final ref = parsed.reference;
  if (ref == null || !_upiReferencePattern.hasMatch(ref)) return null;

  final existing = await database.getTransactionByParsedReference(ref);
  if (existing == null) return null;

  final existingCand = await _existingCandidate(existing, parsed);
  final statementCand = _statementCandidate(parsed);
  final better = _enricher.enrichedMerchant(existingCand, statementCand);
  if (better != null) {
    await _updateMerchant(existing, better);
    return CaptureOutcome.enriched;
  }
  return CaptureOutcome.duplicate;
}

/// Window-based enrichment: scan captured transactions within ±[kEnrichMatchWindow]
/// and, if one matches by the loose fallback rule and is enrichable from
/// [parsed]'s (non-generic) merchant, upgrade it. Returns true if it enriched.
Future<bool> _tryWindowEnrichment(ParsedTransaction parsed) async {
  final statementCand = _statementCandidate(parsed);
  // A generic incoming merchant can't enrich anything.
  if (_enricher.isGeneric((parsed.merchant ?? '').trim())) return false;

  final near = await database.getCapturedTransactionsInRange(
    parsed.timestamp.subtract(kEnrichMatchWindow),
    parsed.timestamp.add(kEnrichMatchWindow),
  );
  for (final existing in near) {
    final existingCand = await _existingCandidate(existing, parsed);
    final matches = _enricher.isFallbackStatementMatch(
            existingCand, statementCand) ||
        _enricher.isAmountDateFallbackEnrichmentCandidate(
            existingCand, statementCand);
    if (!matches) continue;
    final better = _enricher.enrichedMerchant(existingCand, statementCand);
    if (better != null) {
      await _updateMerchant(existing, better);
      return true;
    }
  }
  return false;
}

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

  // 1b. Reference-based enrich/dedup. If this UPI ref already maps to a captured
  //     transaction, either enrich its merchant or treat it as a duplicate.
  //     Either way, nothing new is inserted.
  final refOutcome = await _tryReferenceEnrichment(parsed);
  if (refOutcome != null) {
    return TransactionCaptureResult(outcome: refOutcome);
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

  // 2b. Cross-source dedup. The same payment can arrive via BOTH an SMS and a
  //     bank-app notification; their bodies differ, so the hash check (step 1)
  //     misses it. Treat it as a duplicate if a recently-captured transaction
  //     has the same magnitude within ±2 min AND shares the wallet or merchant
  //     (the guard prevents merging two genuinely distinct same-amount txns).
  // 2b-i. First try to ENRICH an in-window candidate from this (non-generic)
  //       merchant before deciding it's a duplicate. This upgrades a generic
  //       "UPI" capture to a real merchant without inserting a new row.
  if (await _tryWindowEnrichment(parsed)) {
    return const TransactionCaptureResult(outcome: CaptureOutcome.enriched);
  }
  if (await _isCrossSourceDuplicate(parsed)) {
    return const TransactionCaptureResult(outcome: CaptureOutcome.duplicate);
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
      parsedReference: parsed.reference,
    ),
  );

  String? insertedPk;
  if (rowId != null) {
    final inserted = await database.getTransactionFromRowId(rowId);
    insertedPk = inserted.transactionPk;
  }

  // 5. Reconcile the bank-reported balance, if we trust the routing. The
  //    reconciler branches on isFromCard: for a credit card the reported
  //    balance is the OUTSTANDING amount and is negated into Cashew's
  //    wallet-balance convention; for debit/savings it is used directly.
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
  // We reconcile against an authoritative balance. For both debit/savings and
  // credit cards that means an explicitly reported balance: for a card the
  // reported balance IS the outstanding amount (the reconciler negates it into
  // Cashew's wallet-balance convention). We do not derive outstanding from
  // creditLimit alone here because the card's *total* sanctioned limit is not
  // available from the wallet, so available-limit alone can't yield outstanding.
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

/// Stable primary key for the "Other / Uncategorized" expense category that
/// captured transactions with no merchant mapping fall into.
///
/// IMPORTANT: this is deliberately NOT pk "0" — pk "0" is Cashew's
/// balance-correction category, which is *excluded* from spending totals. A
/// captured bank transaction whose merchant we couldn't map is still a real
/// expense and must COUNT, so it routes here (income:false, a normal category).
///
/// This mirrors PennyWise, which assigns an "Others" / "Uncategorized" category
/// to transactions with no merchant mapping (see
/// `ui/icons/CategoryMapping.kt` "Others" and AnalyticsViewModel's
/// `category.ifEmpty { "Others" }`).
const String kUncategorizedCategoryPk = "uncategorized";

/// The default / uncategorized category for unmatched merchants.
///
/// Ensures a stable, real expense category (`kUncategorizedCategoryPk`,
/// income:false) exists and returns it. Reused across SMS / PDF / mandate
/// capture. Unlike the balance-correction category ("0"), this one is counted
/// in spending totals. Returns null only if creation fails unexpectedly, in
/// which case the capture is reported unmapped.
Future<TransactionCategory?> _defaultCategory() async {
  try {
    final existing =
        await database.getCategoryInstanceOrNull(kUncategorizedCategoryPk);
    if (existing != null) return existing;

    final int numberOfCategories =
        (await database.getTotalCountOfCategories())[0] ?? 0;
    await database.createOrUpdateCategory(
      // insert:false = upsert that PRESERVES the provided pk (insert:true would
      // generate a fresh UUID, leaving the lookup below to fail). Mirrors
      // initializeBalanceCorrectionCategory.
      insert: false,
      updateSharedEntry: false,
      TransactionCategory(
        categoryPk: kUncategorizedCategoryPk,
        // No dedicated translation key yet; "Other" reads sensibly and the
        // user can rename it. PennyWise uses the literal "Others".
        name: "Other",
        colour: toHexString(Colors.blueGrey),
        iconName: "box.png",
        dateCreated: DateTime.now(),
        dateTimeModified: null,
        order: numberOfCategories,
        income: false,
      ),
    );
    return await database.getCategoryInstanceOrNull(kUncategorizedCategoryPk);
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
