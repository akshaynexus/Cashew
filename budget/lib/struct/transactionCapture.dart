// Transaction-capture orchestrator.
//
// Turns a parser-produced [ParsedTransaction] (from the cashew_pennywise SMS /
// PDF parsers) into a Cashew [Transaction], with:
//  - hash-based deduplication (skip if we already captured this message),
//  - account routing by (bankName, accountLast4) -> Wallet.
//
// This is the single glue point between the plugin's pure parsing/decision
// logic and Cashew's Drift database.

import 'package:budget/colors.dart';
import 'package:budget/database/tables.dart';
import 'package:budget/pages/addTransactionPage.dart';
import 'package:budget/struct/databaseGlobal.dart';
import 'package:budget/struct/settings.dart';
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

  const TransactionCaptureResult({
    required this.outcome,
    this.transactionPk,
  });

  bool get wasInserted => outcome == CaptureOutcome.inserted;

  @override
  String toString() => 'TransactionCaptureResult($outcome, '
      'transactionPk=$transactionPk)';
}

/// Window for cross-source (SMS vs notification) duplicate matching, mirroring
/// PennyWise's ±2-minute amount+bank match in its native notification listener.
const Duration kCrossSourceWindow = Duration(minutes: 2);

/// PennyWise's UPI RRN duplicate window.
const Duration kUpiReferenceWindow = Duration(minutes: 3);

bool _typesCompatible(Transaction existing, ParsedTransaction parsed) {
  if (existing.income) return parsed.type == ParsedTransactionType.income;
  return parsed.type != ParsedTransactionType.income;
}

bool _last4Compatible(String? existingLast4, String? parsedLast4) {
  final existing = existingLast4 == null ? '' : _normalizeLast4(existingLast4);
  final parsed = parsedLast4 == null ? '' : _normalizeLast4(parsedLast4);
  return existing.isEmpty || parsed.isEmpty || existing == parsed;
}

bool _currencyCompatible(TransactionWallet? wallet, ParsedTransaction parsed) {
  final walletCurrency = wallet?.currency;
  return walletCurrency == null ||
      walletCurrency.isEmpty ||
      walletCurrency.toLowerCase() == parsed.currency.toLowerCase();
}

Future<bool> _transactionMatchesParsed(
  Transaction existing,
  ParsedTransaction parsed, {
  required Duration window,
}) async {
  if ((existing.amount.abs() - parsed.signedAmount.abs()).abs() > 0.001) {
    return false;
  }
  if (!_typesCompatible(existing, parsed)) return false;
  if (existing.dateCreated.difference(parsed.timestamp).abs() > window) {
    return false;
  }

  final wallet = await database.getWalletInstanceOrNull(existing.walletFk);
  if (!_last4Compatible(wallet?.accountLast4, parsed.accountLast4)) {
    return false;
  }
  if (!_currencyCompatible(wallet, parsed)) return false;
  return true;
}

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
    if (!await _transactionMatchesParsed(
      t,
      parsed,
      window: kCrossSourceWindow,
    )) {
      continue;
    }
    if (t.name.trim().toLowerCase() == merchant) return true;
  }
  return false;
}

const TransactionEnricher _enricher = TransactionEnricher();

String _normalizeAccountKey(String value) =>
    value.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');

String _normalizeLast4(String value) => value.replaceAll(RegExp(r'\D'), '');

/// Finds a wallet for the parsed bank account/card. The exact DB query is kept
/// for the common path; the in-memory normalized pass avoids duplicates caused
/// by bank-name casing/spacing changes from parser updates.
Future<TransactionWallet?> _findWalletForParsedAccount(
  String bankName,
  String accountLast4,
) async {
  final normalizedLast4 = _normalizeLast4(accountLast4);
  if (normalizedLast4.isEmpty) return null;

  final exact =
      await database.getWalletByBankAndLast4(bankName, normalizedLast4);
  if (exact != null) return exact;

  final normalizedBank = _normalizeAccountKey(bankName);
  for (final wallet in await database.getAllWallets()) {
    final walletLast4 = wallet.accountLast4;
    if (walletLast4 == null) continue;
    if (_normalizeLast4(walletLast4) != normalizedLast4) continue;
    final walletBank = wallet.bankName;
    if (walletBank == null || walletBank.trim().isEmpty) continue;
    if (_normalizeAccountKey(walletBank) == normalizedBank) return wallet;
  }
  return null;
}

/// Creates a dedicated Cashew account for a bank account/card seen in an SMS.
/// This prevents unidentified cards from being booked against the selected
/// wallet and driving a main account negative.
Future<TransactionWallet?> _createWalletForParsedAccount(
  ParsedTransaction parsed,
  String accountLast4,
) async {
  final normalizedLast4 = _normalizeLast4(accountLast4);
  if (normalizedLast4.isEmpty) return null;

  final bankName =
      parsed.bankName.trim().isEmpty ? 'Bank' : parsed.bankName.trim();
  final walletName = parsed.isFromCard
      ? '$bankName Card $normalizedLast4'
      : '$bankName Account $normalizedLast4';
  final numberOfWallets = (await database.getTotalCountOfWallets())[0] ?? 0;

  final rowId = await database.createOrUpdateWallet(
    insert: true,
    TransactionWallet(
      walletPk: "-1",
      name: walletName,
      colour: toHexString(parsed.isFromCard ? Colors.deepPurple : Colors.blue),
      iconName: parsed.isFromCard ? "credit-card.png" : "bank.png",
      dateCreated: DateTime.now(),
      dateTimeModified: null,
      order: numberOfWallets,
      currency: parsed.currency,
      decimals: 2,
      homePageWidgetDisplay: defaultWalletHomePageWidgetDisplay,
      bankName: bankName,
      accountLast4: normalizedLast4,
    ),
  );
  return database.getWalletFromRowId(rowId);
}

/// Matches a 12-digit UPI RRN — the reference key used for reference-based
/// enrichment (a PDF statement row and the original SMS share this).
final RegExp _upiReferencePattern = RegExp(r'^\d{12}$');

/// Maps the incoming [parsed] transaction to a statement [EnrichCandidate].
EnrichCandidate _statementCandidate(ParsedTransaction parsed) =>
    EnrichCandidate(
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
    // Cashew stores a single per-wallet currency. The reference/account match
    // already anchors identity, so use the incoming currency for comparison.
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
Future<CaptureOutcome?> _tryReferenceEnrichment(
    ParsedTransaction parsed) async {
  final ref = parsed.reference;
  if (ref == null || !_upiReferencePattern.hasMatch(ref)) return null;

  final existingRows = await database.getTransactionsByParsedReference(ref);
  final statementCand = _statementCandidate(parsed);
  for (final existing in existingRows) {
    if (!await _transactionMatchesParsed(
      existing,
      parsed,
      window: kUpiReferenceWindow,
    )) {
      continue;
    }

    final existingCand = await _existingCandidate(existing, parsed);
    final better = _enricher.enrichedMerchant(existingCand, statementCand);
    if (better != null) {
      await _updateMerchant(existing, better);
      return CaptureOutcome.enriched;
    }
    return CaptureOutcome.duplicate;
  }
  return null;
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
    if (!await _transactionMatchesParsed(
      existing,
      parsed,
      window: kUpiReferenceWindow,
    )) {
      continue;
    }
    final existingCand = await _existingCandidate(existing, parsed);
    final matches =
        _enricher.isFallbackStatementMatch(existingCand, statementCand) ||
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
///
/// Reported SMS balances are deliberately NOT written as balance-correction
/// transactions. PennyWise stores them as account/card balance metadata; Cashew
/// currently has no separate balance-history model, so mutating the ledger to
/// force a match would create fake transactions and corrupt spending history.
Future<TransactionCaptureResult> captureParsedTransaction(
  ParsedTransaction parsed,
) async {
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

  // 2. Resolve the wallet. Like PennyWise, account identity comes from the
  //    parser's bank name + account/card last4. If Cashew has not seen this
  //    account before, create a dedicated wallet for it instead of polluting
  //    the selected fallback wallet.
  TransactionWallet? wallet;
  final last4 = parsed.accountLast4;
  if (last4 != null && last4.isNotEmpty) {
    wallet = await _findWalletForParsedAccount(parsed.bankName, last4);
    if (wallet == null) {
      wallet = await _createWalletForParsedAccount(parsed, last4);
    }
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

  final String name =
      (merchant != null && merchant.isNotEmpty) ? merchant : parsed.bankName;

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

  return TransactionCaptureResult(
    outcome: CaptureOutcome.inserted,
    transactionPk: insertedPk,
  );
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
