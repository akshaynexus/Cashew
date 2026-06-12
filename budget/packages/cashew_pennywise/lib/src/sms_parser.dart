import 'package:flutter/services.dart';

import 'parsed_transaction.dart';

/// Dart-side handle to the vendored PennyWise SMS parser (Kotlin parser-core),
/// reached over a MethodChannel. Android only — SMS parsing has no iOS path.
///
/// This wraps the parser ONLY. The inbox-scan orchestration (the Dart port of
/// OptimizedSmsReaderWorker) lives in `sms_scanner.dart` and calls [parseBatch].
class SmsParser {
  SmsParser({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel('cashew_pennywise/parser');

  final MethodChannel _channel;

  /// Number of bank parsers compiled into the AAR. Doubles as a health check
  /// that the vendored parser-core is present and linked.
  Future<int> parserCount() async {
    final count = await _channel.invokeMethod<int>('ping');
    return count ?? 0;
  }

  /// True if any registered bank parser recognizes [sender].
  Future<bool> isKnownSender(String sender) async {
    final known =
        await _channel.invokeMethod<bool>('isKnownSender', {'sender': sender});
    return known ?? false;
  }

  /// Parse a single message. Returns null if no parser handled it (OTP, promo,
  /// unknown sender, etc.).
  Future<ParsedTransaction?> parse(RawMessage message) async {
    final map = await _channel.invokeMethod<Map<dynamic, dynamic>>(
      'parse',
      message.toChannelMap(),
    );
    return map == null ? null : ParsedTransaction.fromMap(map);
  }

  /// Detect an e-mandate / subscription in [message]. Returns null if the
  /// message isn't a mandate notification. A mandate-setup SMS usually does NOT
  /// parse as a transaction (no debit), so try this on messages [parse] missed.
  Future<ParsedMandate?> parseMandate(RawMessage message) async {
    final map = await _channel.invokeMethod<Map<dynamic, dynamic>>('parseMandate', {
      'sender': message.sender,
      'body': message.body,
    });
    return map == null ? null : ParsedMandate.fromMap(map);
  }

  /// Parse many messages in one channel round-trip. Unparseable entries are
  /// dropped, so the result length may be < [messages] length. This is the hot
  /// path for inbox scanning — batch to avoid per-message channel overhead.
  Future<List<ParsedTransaction>> parseBatch(List<RawMessage> messages) async {
    if (messages.isEmpty) return const [];
    final list = await _channel.invokeMethod<List<dynamic>>('parseBatch', {
      'messages': messages.map((m) => m.toChannelMap()).toList(),
    });
    if (list == null) return const [];
    return list
        .whereType<Map<dynamic, dynamic>>()
        .map(ParsedTransaction.fromMap)
        .toList();
  }
}
