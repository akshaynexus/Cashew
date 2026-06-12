# cashew_pennywise

Bridges [PennyWise AI](https://github.com/akshaynexus/pennywiseai-tracker)'s
transaction parsers into Cashew.

## Design

| Capability | Strategy | Platforms |
|---|---|---|
| Bank **SMS** parsing (120+ banks) | **Wrap** PennyWise's pure-Kotlin `parser-core`, compiled into this AAR and called over a MethodChannel. Never reimplemented in Dart. | Android |
| SMS inbox scan / dedup | Pure-Dart port of `OptimizedSmsReaderWorker`; delegates parsing to the wrapped Kotlin via `parseBatch`. | Android |
| Bank-app **notification** parsing | Native Android `NotificationListenerService` wrapper → same Kotlin parser. | Android |
| **GPay / PhonePe PDF** statements | Pure-Dart port of the `shared/` statement parsers; text extracted with `pdfrx`. | Android + iOS |

The SMS parser is the single source of truth: it lives upstream in Kotlin and is
**vendored**, not copied by hand.

## Updating the vendored parser

The parser-core source is **not checked in** (`android/vendor/` is git-ignored).
Populate or update it with:

```bash
tool/sync_parser_core.sh                 # use the pinned ref in tool/parser_core.lock
tool/sync_parser_core.sh --ref <sha>     # pull a newer upstream commit
```

The script sparse-clones the pinned commit, copies `parser-core/src` into
`android/vendor/parser-core/kotlin`, copies the GPay/PhonePe statement parsers
into `tool/reference/` (read-only reference for the Dart PDF port), and stamps
the resolved SHA back into `tool/parser_core.lock`.

**Run it once after a fresh checkout**, before building.

## Status / TODO

Legend: ✅ done & verified · 🟡 done, needs runtime/on-device verification · ⬜ not started

### Parser wrapping (plugin core)
- ✅ Vendoring script + pinned ref (`tool/sync_parser_core.sh`) — pulls upstream `parser-core`
- ✅ Vendored Kotlin compiles & parses real SMS — **JVM suite: 1236 tests pass**; vendored copy byte-identical to upstream
- ✅ Kotlin plugin `parse` / `parseBatch` over MethodChannel + Dart `SmsParser` + `ParsedTransaction` contract
- ✅ Plugin AAR / example-app compiles the vendored Kotlin (Android Gradle wiring confirmed)
- 🟡 Live MethodChannel round-trip on a real device/emulator (Dart ↔ running AAR) — not yet exercised

### SMS capture (Android)
- ✅ Inbox-scan orchestration ported to Dart (`SmsScanner`, `SmsInbox`, `SmsLiveStream`)
- ✅ SMS / notification permission handling (`SmsPermissions`) + manifest + native handlers
- 🟡 Live incoming-SMS receiver + multipart reassembly — coded, needs on-device verification

### PDF statements (cross-platform)
- ✅ GPay/PhonePe parser port to pure Dart (`pdfrx`) — `StatementImporter`; **15 parser tests pass**

### Cashew integration
- ✅ Schema v47: `MethodAdded.parsed`, `Transactions.transactionHash`, `Wallets.bankName`/`accountLast4`, `UnrecognizedSms` table + migration + queries
- ✅ Dedup (`CaptureDeduplicator`) + bank-balance reconciliation (`BalanceReconciler`) — pure, **29 tests pass**
- ✅ Capture orchestrator `lib/struct/transactionCapture.dart` (parse → dedup → account/category map → insert → reconcile)
- ✅ Unrecognized-SMS review queue UI (`pages/autoTransactionsPageEmail.dart` + `widgets/unrecognizedSmsQueue.dart`)
- ✅ **End-to-end pipeline test passes** (`budget/test/sms_capture_pipeline_test.dart`): fake inbox → `SmsScanner` → `captureParsedTransaction` → real in-memory Drift DB; asserts insert/dedup/last4-routing/reconciliation/queue

### Dependency migration (Flutter 3.44.1 / latest majors — needed for the app to compile)
- ✅ `intl ^0.20.2`; `cashew_pennywise` path dep added; `build_runner` regen of `tables.g.dart`
- ✅ `cloud_firestore`×`drift` name clash (`hide` in `tables.dart`); `flutter_local_notifications` v22; `csv` v8; `fl_chart` 1.2; `local_auth` 3; `flutter_timezone`
- ✅ `flutter analyze lib` = **0 errors**
- 🟡 `google_sign_in` v6→7.2.0 — compiles; **auth / Drive / Gmail / Sheets flow needs on-device re-verification** (v7 split auth from authorization)

### Capture entry point (wired this pass)
- ✅ `struct/smsCaptureService.dart` — `runHistoricalSmsScan()` (scan → capture → reconcile), live `startSmsLiveCapture()`/`stopSmsLiveCapture()`, `initSmsCaptureIfEnabled()` (startup), `importSmsStatement()` (PDF)
- ✅ Auto-enqueue unrecognized: `SmsScanner` now surfaces known-sender-but-unparsed messages (`SmsScanProgress.unrecognized`/`onUnrecognized`); the service enqueues them
- ✅ Settings page `pages/autoTransactionsPageSms.dart` (enable toggle + permission request, "scan now", PDF import, review queue) + entry in `pages/settingsPage.dart`; default `smsScanning:false`; startup hook in `main.dart`
- ✅ **Mandate → subscription detection**: bridge `parseMandate` (Kotlin `MandateInfo` dispatch) → Dart `ParsedMandate` → `captureMandate()` creates a Cashew recurring `TransactionSpecialType.subscription` (monthly, next-deduction date, UMN-based dedup) reusing the existing engine; the service tries it on known-sender messages before queueing them
- ✅ **Tests pass** (`budget/test/`): `sms_capture_service_test` (scan→capture→auto-enqueue→reconcile), `sms_mandate_test` (mandate→subscription + dedup, via direct call and via scan), `sms_capture_pipeline_test`
- 🟡 Runtime on real Android device (permission dialog, live delivery, actual inbox) — not yet exercised

### Pending / not started
- ⬜ `NotificationListenerService` wrapper (parse bank-app notifications through the same parser)
- ⬜ Add the new UI translation keys to `assets/translations/translations.csv` + regen (keys: `automatic-sms-transactions`, `scan-bank-sms`(+`-description`), `scan-inbox-now`(+`-description`), `import-pdf-statement`(+`-description`), `scan-complete`, `import-complete`, `import-failed`, `could-not-read-pdf`, `permission-denied`, `sms-permission-needed`)
- ⬜ Password-protected PDF prompt (UI for `importSmsStatement(password:)`)
- ⬜ Product decision: unmatched-merchant captures → balance-correction/uncategorized category vs. skip (email flow skips)
- ⬜ Credit-card reconciliation (outstanding + `creditLimit`) — reconciler currently v1 (debit/savings)

See [FEATURE_GAP.md](FEATURE_GAP.md) for the PennyWise-vs-Cashew analysis and the prioritized port roadmap.
