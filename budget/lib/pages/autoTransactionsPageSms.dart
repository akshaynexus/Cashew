import 'package:budget/functions.dart';
import 'package:budget/pages/addTransactionPage.dart';
import 'package:budget/struct/settings.dart';
import 'package:budget/struct/smsCaptureService.dart';
import 'package:budget/widgets/framework/pageFramework.dart';
import 'package:budget/widgets/framework/popupFramework.dart';
import 'package:budget/widgets/globalSnackbar.dart';
import 'package:budget/widgets/openBottomSheet.dart';
import 'package:budget/widgets/openSnackbar.dart';
import 'package:budget/widgets/settingsContainers.dart';
import 'package:budget/widgets/unrecognizedSmsQueue.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

/// Settings surface for automatic SMS transaction capture (Android) and
/// GPay/PhonePe PDF statement import (cross-platform). Mirrors the email
/// auto-transactions page conventions.
class AutoTransactionsPageSms extends StatefulWidget {
  const AutoTransactionsPageSms({super.key});

  @override
  State<AutoTransactionsPageSms> createState() =>
      _AutoTransactionsPageSmsState();
}

class _AutoTransactionsPageSmsState extends State<AutoTransactionsPageSms> {
  bool _scanning = false;

  bool get _isAndroid => getPlatform() == PlatformOS.isAndroid;

  Future<void> _onToggle(bool enabled) async {
    if (enabled) {
      final granted = await smsPermissions.requestSmsPermissions();
      if (!granted) {
        await updateSettings("smsScanning", false, updateGlobalState: false);
        openSnackbar(SnackbarMessage(
          title: "permission-denied".tr(),
          description: "sms-permission-needed".tr(),
          icon: Icons.sms_failed_rounded,
        ));
        setState(() {});
        return;
      }
      await updateSettings("smsScanning", true, updateGlobalState: false);
      startSmsLiveCapture();
    } else {
      await updateSettings("smsScanning", false, updateGlobalState: false);
      await stopSmsLiveCapture();
    }
    setState(() {});
  }

  Future<void> _onNotificationToggle(bool enabled) async {
    if (enabled) {
      final granted = await smsPermissions.hasNotificationAccess();
      if (!granted) {
        await smsPermissions.openNotificationAccessSettings();
        await updateSettings("notificationCaptureScanning", false,
            updateGlobalState: false);
        openSnackbar(SnackbarMessage(
          title: "notification-access-needed".tr(),
          description: "notification-access-needed-description".tr(),
          icon: Icons.notifications_off_rounded,
        ));
        setState(() {});
        return;
      }
      await updateSettings("notificationCaptureScanning", true,
          updateGlobalState: false);
      startNotificationCapture();
    } else {
      await updateSettings("notificationCaptureScanning", false,
          updateGlobalState: false);
      await stopNotificationCapture();
    }
    setState(() {});
  }

  Future<void> _scanNow() async {
    if (_scanning) return;
    setState(() => _scanning = true);
    try {
      final summary = await runHistoricalSmsScan();
      openSnackbar(SnackbarMessage(
        title: "scan-complete".tr(),
        description: "${summary.inserted} added · ${summary.subscriptions} "
            "subscriptions · ${summary.duplicate} duplicates · "
            "${summary.unrecognized} unrecognized",
        icon: Icons.sms_rounded,
      ));
    } finally {
      if (mounted) setState(() => _scanning = false);
    }
  }

  Future<void> _importPdf() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['pdf'],
    );
    final path = result?.files.single.path;
    if (path == null) return;
    await _runPdfImport(path);
  }

  /// Attempts a statement import. On failure (or an empty result, which usually
  /// signals a password-protected PDF) prompts the user for a password and
  /// retries once with [password].
  Future<void> _runPdfImport(String path, {String? password}) async {
    try {
      final summary = await importSmsStatement(path, password: password);
      if (summary.scanned == 0 && password == null) {
        _promptPdfPassword(path);
        return;
      }
      openSnackbar(SnackbarMessage(
        title: "import-complete".tr(),
        description: "${summary.inserted} added · ${summary.enriched} "
            "enriched · ${summary.duplicate} duplicates",
        icon: Icons.picture_as_pdf_rounded,
      ));
    } catch (e) {
      if (password == null) {
        _promptPdfPassword(path);
        return;
      }
      openSnackbar(SnackbarMessage(
        title: "import-failed".tr(),
        description: "could-not-read-pdf".tr(),
        icon: Icons.error_rounded,
      ));
    }
  }

  void _promptPdfPassword(String path) {
    openBottomSheet(
      context,
      popupWithKeyboard: true,
      PopupFramework(
        title: "enter-pdf-password".tr(),
        subtitle: "enter-pdf-password-description".tr(),
        child: SelectText(
          buttonLabel: "import".tr(),
          icon: Icons.lock_rounded,
          setSelectedText: (_) {},
          nextWithInput: (password) async {
            await _runPdfImport(path, password: password);
          },
          placeholder: "password".tr(),
          autoFocus: true,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final enabled = appStateSettings["smsScanning"] == true;
    return PageFramework(
      title: "automatic-sms-transactions".tr(),
      listWidgets: [
        if (_isAndroid)
          SettingsContainerSwitch(
            title: "scan-bank-sms".tr(),
            description: "scan-bank-sms-description".tr(),
            icon: Icons.sms_rounded,
            initialValue: enabled,
            onSwitched: _onToggle,
          ),
        if (_isAndroid)
          SettingsContainerSwitch(
            title: "notification-transactions".tr(),
            description: "notification-transactions-description".tr(),
            icon: Icons.notifications_active_rounded,
            initialValue:
                appStateSettings["notificationCaptureScanning"] ?? false,
            onSwitched: _onNotificationToggle,
          ),
        if (_isAndroid && enabled)
          SettingsContainer(
            title: "scan-inbox-now".tr(),
            description: "scan-inbox-now-description".tr(),
            icon: _scanning ? Icons.hourglass_top_rounded : Icons.refresh_rounded,
            onTap: _scanNow,
          ),
        SettingsContainer(
          title: "import-pdf-statement".tr(),
          description: "import-pdf-statement-description".tr(),
          icon: Icons.picture_as_pdf_rounded,
          onTap: _importPdf,
        ),
        const UnrecognizedSmsQueue(),
      ],
    );
  }
}
