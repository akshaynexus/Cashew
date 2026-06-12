import 'dart:async';

import 'package:budget/functions.dart';
import 'package:budget/struct/settings.dart';
import 'package:budget/struct/transactionCapture.dart';
import 'package:cashew_pennywise/cashew_pennywise.dart';

/// Orchestrates automatic transaction capture for Cashew: it connects the
/// PennyWise plugin (inbox scan, live SMS, PDF statements) to Cashew's
/// [captureParsedTransaction] persistence + reconciliation layer.
///
/// SMS capture is Android-only (the plugin's channels no-op elsewhere); PDF
/// import is cross-platform. This file owns the entry points the UI calls.

/// Tally of a capture run.
class SmsCaptureSummary {
  int inserted = 0;
  int duplicate = 0;
  int unmapped = 0;
  int unrecognized = 0;
  int subscriptions = 0;
  int scanned = 0;

  void _add(CaptureOutcome outcome) {
    switch (outcome) {
      case CaptureOutcome.inserted:
        inserted++;
        break;
      case CaptureOutcome.duplicate:
        duplicate++;
        break;
      case CaptureOutcome.unmapped:
        unmapped++;
        break;
    }
  }

  @override
  String toString() =>
      'SmsCaptureSummary(scanned=$scanned, inserted=$inserted, '
      'duplicate=$duplicate, unmapped=$unmapped, subscriptions=$subscriptions, '
      'unrecognized=$unrecognized)';
}

final SmsParser _parser = SmsParser();
final SmsPermissions smsPermissions = SmsPermissions();
StreamSubscription<RawMessage>? _liveSubscription;

/// Whether SMS capture/scanning is available. **Android-only** — SMS inbox and
/// live SMS are inaccessible on iOS/web/desktop. Overridable in tests.
bool Function() smsCaptureSupported =
    () => getPlatform() == PlatformOS.isAndroid;

/// Runs a historical inbox scan, capturing each parsed transaction and
/// enqueueing known-sender messages the parser couldn't handle. DB writes are
/// serialized (awaited in order) so dedup + balance reconciliation stay correct.
///
/// [onProgress] is called per page so the UI can drive a progress indicator.
Future<SmsCaptureSummary> runHistoricalSmsScan({
  DateTime? since,
  void Function(SmsScanProgress progress)? onProgress,
}) async {
  final summary = SmsCaptureSummary();
  if (!smsCaptureSupported()) return summary; // Android-only.

  await for (final progress in SmsScanner().scanInbox(since: since)) {
    summary.scanned = progress.processed;
    for (final tx in progress.newTransactions) {
      final result = await captureParsedTransaction(tx);
      summary._add(result.outcome);
    }
    for (final message in progress.unrecognized) {
      // A known-sender message the parser couldn't turn into a transaction may
      // still be an e-mandate / subscription. Try that before queueing it.
      final mandate = await _parser.parseMandate(message);
      if (mandate != null) {
        if (await captureMandate(mandate) == MandateCaptureOutcome.created) {
          summary.subscriptions++;
        }
      } else {
        await enqueueUnrecognized(message.sender, message.body);
        summary.unrecognized++;
      }
    }
    onProgress?.call(progress);
  }

  await updateSettings("smsLastScanTimestamp",
      DateTime.now().millisecondsSinceEpoch,
      updateGlobalState: false);
  return summary;
}

/// Starts listening for live incoming SMS and capturing them. Idempotent.
void startSmsLiveCapture() {
  if (!smsCaptureSupported() || _liveSubscription != null) return;
  _liveSubscription = SmsLiveStream().messages.listen(_handleLiveMessage);
}

/// Stops the live listener.
Future<void> stopSmsLiveCapture() async {
  await _liveSubscription?.cancel();
  _liveSubscription = null;
}

Future<void> _handleLiveMessage(RawMessage message) async {
  final parsed = await _parser.parse(message);
  if (parsed != null) {
    await captureParsedTransaction(parsed);
    return;
  }
  final mandate = await _parser.parseMandate(message);
  if (mandate != null) {
    await captureMandate(mandate);
    return;
  }
  if (await _parser.isKnownSender(message.sender)) {
    await enqueueUnrecognized(message.sender, message.body);
  }
}

/// Called at app startup. If SMS capture is enabled and permitted, starts the
/// live listener and kicks off a non-blocking catch-up scan for anything that
/// arrived while the app was closed.
Future<void> initSmsCaptureIfEnabled() async {
  if (!smsCaptureSupported()) return;
  if (appStateSettings["smsScanning"] != true) return;
  if (!await smsPermissions.hasSmsPermissions()) return;

  startSmsLiveCapture();

  // Catch up on messages missed while closed, since the last successful scan.
  final lastMillis = appStateSettings["smsLastScanTimestamp"];
  final since = lastMillis is int
      ? DateTime.fromMillisecondsSinceEpoch(lastMillis)
      : null;
  // Fire-and-forget — don't block app launch on a full inbox scan.
  unawaited(runHistoricalSmsScan(since: since));
}

/// Imports a GPay/PhonePe PDF statement (cross-platform) and captures each
/// transaction. [password] is required for password-protected statements.
Future<SmsCaptureSummary> importSmsStatement(
  String filePath, {
  String? password,
}) async {
  final summary = SmsCaptureSummary();
  final transactions = await const StatementImporter()
      .importStatement(filePath, password: password);
  summary.scanned = transactions.length;
  for (final tx in transactions) {
    final result = await captureParsedTransaction(tx);
    summary._add(result.outcome);
  }
  return summary;
}
