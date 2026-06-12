import 'package:flutter/services.dart';

import 'parsed_transaction.dart';

/// Reads the device SMS inbox via the native `readInbox` MethodChannel call.
/// Android only. Returns [RawMessage]s ordered by timestamp ascending.
///
/// The native query supports pagination so a large inbox can be walked without
/// loading every message into memory at once:
///  - [since]  : inclusive lower bound on message time (null = all time).
///  - [before] : exclusive upper bound on message time (null = no upper bound).
///  - [limit]  : max messages to return in this page (null = unbounded).
///
/// The default forward-paging strategy used by [SmsScanner] is: read a page with
/// [since] + [limit], then advance [since] to one past the last message's
/// timestamp for the next page (see [pageForward]).
class SmsInbox {
  SmsInbox({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel('cashew_pennywise/parser');

  final MethodChannel _channel;

  /// One raw inbox read. Thin wrapper over the native call.
  Future<List<RawMessage>> readInbox({
    DateTime? since,
    DateTime? before,
    int? limit,
  }) async {
    final list = await _channel.invokeMethod<List<dynamic>>('readInbox', {
      'sinceEpochMillis': since?.millisecondsSinceEpoch,
      'beforeEpochMillis': before?.millisecondsSinceEpoch,
      'limit': limit,
    });
    if (list == null) return const [];
    return list
        .whereType<Map<dynamic, dynamic>>()
        .map(_rawFromMap)
        .toList(growable: false);
  }

  /// Forward-paging async iterator over the inbox. Yields one page (list of
  /// [RawMessage]) at a time, ordered ascending by timestamp, until an empty
  /// page is returned. Pages are advanced by moving the lower bound to
  /// `lastTimestamp + 1ms`, so a page boundary that lands inside a cluster of
  /// same-millisecond messages does not drop or duplicate rows.
  Stream<List<RawMessage>> pageForward({
    DateTime? since,
    int pageSize = 500,
  }) async* {
    var cursor = since;
    while (true) {
      final page = await readInbox(since: cursor, limit: pageSize);
      if (page.isEmpty) return;
      yield page;
      // If the provider returned fewer than a full page, the inbox is exhausted.
      if (page.length < pageSize) return;
      final lastTs = page.last.timestamp;
      cursor = lastTs.add(const Duration(milliseconds: 1));
    }
  }

  static RawMessage _rawFromMap(Map<dynamic, dynamic> map) => RawMessage(
        sender: map['sender'] as String? ?? '',
        body: map['body'] as String? ?? '',
        timestamp: DateTime.fromMillisecondsSinceEpoch(
          (map['timestamp'] as num?)?.toInt() ?? 0,
        ),
      );
}
