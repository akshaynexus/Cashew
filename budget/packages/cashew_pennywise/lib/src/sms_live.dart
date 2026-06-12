import 'package:flutter/services.dart';

import 'parsed_transaction.dart';

/// Live incoming-SMS stream over the `cashew_pennywise/sms_stream` EventChannel.
/// Android only. Each event is one (already multi-part-reassembled) message.
///
/// The native side registers a `SMS_RECEIVED` broadcast receiver only while
/// [messages] has an active listener, so simply not listening tears down the
/// receiver. Pair this with [SmsParser] / [SmsScanner]'s parse path to turn live
/// messages into transactions.
class SmsLiveStream {
  SmsLiveStream({EventChannel? channel})
      : _channel =
            channel ?? const EventChannel('cashew_pennywise/sms_stream');

  final EventChannel _channel;

  Stream<RawMessage>? _cached;

  /// Broadcast stream of incoming messages. Cached so multiple subscribers
  /// share one native receiver registration.
  Stream<RawMessage> get messages {
    return _cached ??= _channel
        .receiveBroadcastStream()
        .map(_rawFromEvent)
        .asBroadcastStream();
  }

  static RawMessage _rawFromEvent(dynamic event) {
    final map = event as Map<dynamic, dynamic>;
    return RawMessage(
      sender: map['sender'] as String? ?? '',
      body: map['body'] as String? ?? '',
      timestamp: DateTime.fromMillisecondsSinceEpoch(
        (map['timestamp'] as num?)?.toInt() ?? 0,
      ),
    );
  }
}
