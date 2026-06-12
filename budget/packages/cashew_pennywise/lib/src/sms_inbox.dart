import 'package:flutter/services.dart';

import 'parsed_transaction.dart';

/// Reads the device SMS inbox via the native `readInbox` MethodChannel call.
/// Android only. Returns [RawMessage]s ordered by timestamp ascending.
///
/// The native query supports pagination so a large inbox can be walked without
/// loading every message into memory at once:
///  - [since]  : inclusive lower bound on message time (null = all time).
///  - [sinceIdExclusive] : when [since] equals a prior page boundary, only
///    include same-timestamp rows with a larger SMS row id.
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
    int? sinceIdExclusive,
    DateTime? before,
    int? limit,
  }) async {
    final list = await _channel.invokeMethod<List<dynamic>>('readInbox', {
      'sinceEpochMillis': since?.millisecondsSinceEpoch,
      'sinceIdExclusive': sinceIdExclusive,
      'beforeEpochMillis': before?.millisecondsSinceEpoch,
      'limit': limit,
    });
    if (list == null) return const [];
    return list
        .whereType<Map<dynamic, dynamic>>()
        .map(_rawFromMap)
        .toList(growable: false);
  }

  /// Forward-paging async iterator over the inbox. Yields one page at a time,
  /// ordered by `(timestamp, id)`, until an empty page is returned. Page
  /// boundaries keep both timestamp and row id so a cluster of same-millisecond
  /// messages is neither dropped nor duplicated.
  Stream<List<RawMessage>> pageForward({
    DateTime? since,
    int pageSize = 500,
  }) async* {
    var cursor = since;
    int? cursorId;
    while (true) {
      final page = await readInbox(
        since: cursor,
        sinceIdExclusive: cursorId,
        limit: pageSize,
      );
      if (page.isEmpty) return;
      yield page;
      // If the provider returned fewer than a full page, the inbox is exhausted.
      if (page.length < pageSize) return;
      final lastTs = page.last.timestamp;
      final lastId = page.last.id;
      if (lastId == null) {
        // Compatibility with older test/native mocks that don't return row ids.
        cursor = lastTs.add(const Duration(milliseconds: 1));
        cursorId = null;
      } else {
        cursor = lastTs;
        cursorId = lastId;
      }
    }
  }

  static RawMessage _rawFromMap(Map<dynamic, dynamic> map) => RawMessage(
        id: (map['id'] as num?)?.toInt(),
        sender: map['sender'] as String? ?? '',
        body: map['body'] as String? ?? '',
        timestamp: DateTime.fromMillisecondsSinceEpoch(
          (map['timestamp'] as num?)?.toInt() ?? 0,
        ),
      );
}
