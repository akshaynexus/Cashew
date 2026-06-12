import 'package:budget/functions.dart';
import 'package:budget/struct/settings.dart';
import 'package:budget/struct/smsCaptureService.dart';
import 'package:budget/widgets/framework/pageFramework.dart';
import 'package:budget/widgets/globalSnackbar.dart';
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
    try {
      final summary = await importSmsStatement(path);
      openSnackbar(SnackbarMessage(
        title: "import-complete".tr(),
        description: "${summary.inserted} added · ${summary.duplicate} "
            "duplicates",
        icon: Icons.picture_as_pdf_rounded,
      ));
    } catch (e) {
      openSnackbar(SnackbarMessage(
        title: "import-failed".tr(),
        description: "could-not-read-pdf".tr(),
        icon: Icons.error_rounded,
      ));
    }
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
