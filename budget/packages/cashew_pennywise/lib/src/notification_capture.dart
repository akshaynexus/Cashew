import 'package:flutter/services.dart';

import 'parsed_transaction.dart';

/// Live bank-app **notification** stream over the
/// `cashew_pennywise/notification_stream` EventChannel. Android only.
///
/// The native [BankNotificationListenerService] forwards
/// `{packageName, title, text, postTime}` for allowlisted bank apps. Here each
/// event is mapped into a [RawMessage] so it funnels through the exact same
/// parser path as live SMS:
///  - `sender`   ← the bank's sender alias (from [_packageToAlias]); falls back
///                 to the raw package name so an unknown bank app still yields a
///                 stable, parser-visible sender.
///  - `body`     ← `title + "\n" + text` (title often carries the merchant /
///                 amount the parsers key on).
///  - `timestamp`← the notification post time.
///
/// The alias map must mirror the native `NotificationConfig.allowedPackages`.
/// The native side already drops non-allowlisted packages, so this map is the
/// alias source of truth and need not re-filter.
class NotificationCapture {
  NotificationCapture({EventChannel? channel})
      : _channel = channel ??
            const EventChannel('cashew_pennywise/notification_stream');

  final EventChannel _channel;

  Stream<RawMessage>? _cached;

  /// package name (lowercase) -> parser sender alias. Mirrors the native
  /// `NotificationConfig.allowedPackages`.
  static const Map<String, String> _packageToAlias = {
    'com.avanza.ambitwizfbl': 'FaysalBank',
    'finansbank.enpara': 'Enpara',
    'com.enparabank.retail': 'Enpara',
  };

  /// Broadcast stream of bank notifications as [RawMessage]s. Cached so multiple
  /// subscribers share one native sink registration.
  Stream<RawMessage> get messages {
    return _cached ??= _channel
        .receiveBroadcastStream()
        .map(_rawFromEvent)
        .asBroadcastStream();
  }

  static RawMessage _rawFromEvent(dynamic event) {
    final map = event as Map<dynamic, dynamic>;
    final packageName = (map['packageName'] as String? ?? '').toLowerCase();
    final title = (map['title'] as String? ?? '').trim();
    final text = (map['text'] as String? ?? '').trim();

    final body = [title, text].where((s) => s.isNotEmpty).join('\n');
    final alias =
        _packageToAlias[packageName] ?? (map['packageName'] as String? ?? '');

    return RawMessage(
      sender: alias,
      body: body,
      timestamp: DateTime.fromMillisecondsSinceEpoch(
        (map['postTime'] as num?)?.toInt() ?? 0,
      ),
    );
  }
}
