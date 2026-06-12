import 'package:flutter/services.dart';

/// Dart wrapper over the native SMS / notification permission methods on the
/// `cashew_pennywise/parser` MethodChannel. Android only.
///
/// "SMS permissions" here means BOTH READ_SMS (needed for the historical inbox
/// scan) and RECEIVE_SMS (needed for the live stream). [requestSmsPermissions]
/// also requests POST_NOTIFICATIONS on Android 13+; its result reflects only the
/// SMS grant (the value that gates capture).
class SmsPermissions {
  SmsPermissions({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel('cashew_pennywise/parser');

  final MethodChannel _channel;

  /// True if READ_SMS and RECEIVE_SMS are both granted.
  Future<bool> hasSmsPermissions() async {
    final granted = await _channel.invokeMethod<bool>('hasSmsPermissions');
    return granted ?? false;
  }

  /// Shows the system permission dialog(s) and resolves to whether SMS access
  /// was granted. Returns immediately as `true` if already granted, and throws
  /// a [PlatformException] (`NO_ACTIVITY`) if no Activity is attached.
  Future<bool> requestSmsPermissions() async {
    final granted = await _channel.invokeMethod<bool>('requestSmsPermissions');
    return granted ?? false;
  }

  /// True if this app is an enabled notification listener.
  Future<bool> hasNotificationAccess() async {
    final granted = await _channel.invokeMethod<bool>('hasNotificationAccess');
    return granted ?? false;
  }

  /// Opens the system notification-listener settings screen so the user can
  /// toggle access on. There is no callback — re-check with
  /// [hasNotificationAccess] after the user returns.
  Future<void> openNotificationAccessSettings() async {
    await _channel.invokeMethod<void>('openNotificationAccessSettings');
  }
}
