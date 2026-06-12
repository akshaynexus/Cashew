import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:cashew_pennywise/src/parsed_transaction.dart';
import 'package:cashew_pennywise/src/sms_inbox.dart';
import 'package:cashew_pennywise/src/sms_scanner.dart';

/// Tests for the SMS capture pipeline (inbox pager + scanner orchestration).
/// The native side is mocked via the MethodChannel; no device required.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('cashew_pennywise/parser');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  /// Build a parser-core-shaped result map for a parsed transaction.
  Map<String, Object?> txMap({
    required String amount,
    required String type,
    required String txId,
    String? reference,
    String? accountLast4,
    String currency = 'INR',
    int timestamp = 1700000000000,
    String sender = 'HDFCBK',
  }) =>
      {
        'amount': amount,
        'type': type,
        'merchant': 'M',
        'reference': reference,
        'accountLast4': accountLast4,
        'balance': null,
        'creditLimit': null,
        'smsBody': 'body',
        'sender': sender,
        'timestamp': timestamp,
        'bankName': 'HDFC Bank',
        'transactionId': txId,
        'isFromCard': false,
        'currency': currency,
        'fromAccount': null,
        'toAccount': null,
      };

  /// Build an inbox row map (sender/body/timestamp).
  Map<String, Object?> inboxRow(int timestamp) => {
        'sender': 'HDFCBK',
        'body': 'msg',
        'timestamp': timestamp,
      };

  group('SmsInbox.pageForward', () {
    test('stops at the first empty page', () async {
      var readInboxCalls = 0;
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'readInbox') {
          readInboxCalls++;
          // First call: one full page of 2; second call: empty -> stop.
          if (readInboxCalls == 1) {
            return [inboxRow(1000), inboxRow(2000)];
          }
          return <Object?>[];
        }
        return null;
      });

      final pages =
          await SmsInbox().pageForward(pageSize: 2).toList();

      // Page 1 had exactly pageSize rows, so a second (empty) read happened.
      expect(readInboxCalls, 2);
      expect(pages, hasLength(1));
      expect(pages.first, hasLength(2));
    });

    test('stops early when a short page is returned (inbox exhausted)',
        () async {
      var readInboxCalls = 0;
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'readInbox') {
          readInboxCalls++;
          return [inboxRow(1000)]; // < pageSize -> done, no extra read
        }
        return null;
      });

      final pages = await SmsInbox().pageForward(pageSize: 5).toList();
      expect(readInboxCalls, 1);
      expect(pages, hasLength(1));
    });

    test('advances the cursor past the last timestamp between pages', () async {
      final sinceArgs = <int?>[];
      var call = 0;
      messenger.setMockMethodCallHandler(channel, (c) async {
        if (c.method == 'readInbox') {
          sinceArgs.add((c.arguments['sinceEpochMillis'] as num?)?.toInt());
          call++;
          if (call == 1) return [inboxRow(1000), inboxRow(2000)];
          return <Object?>[];
        }
        return null;
      });

      await SmsInbox().pageForward(pageSize: 2).toList();

      expect(sinceArgs[0], isNull); // first page: no lower bound
      expect(sinceArgs[1], 2001); // advanced to lastTs + 1ms
    });
  });

  group('SmsScanner.scanInbox', () {
    test('paging stops at empty page and reports a final done event', () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        switch (call.method) {
          case 'readInbox':
            // Single short page -> exhausted.
            return [inboxRow(1000)];
          case 'parseBatch':
            return [txMap(amount: '10.00', type: 'EXPENSE', txId: 'a')];
        }
        return null;
      });

      final events = await SmsScanner().scanInbox(pageSize: 5).toList();

      expect(events.last.done, isTrue);
      expect(events.last.processed, 1);
      expect(events.last.found, 1);
      // Exactly one page event + one done event.
      expect(events.where((e) => !e.done), hasLength(1));
    });

    test('within-scan dedup drops duplicate transactionIds across pages',
        () async {
      var page = 0;
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'readInbox') {
          page++;
          if (page == 1) return [inboxRow(1000), inboxRow(2000)];
          if (page == 2) return [inboxRow(3000), inboxRow(4000)];
          return <Object?>[];
        }
        if (call.method == 'parseBatch') {
          // Both pages emit a transaction with the SAME id "dup" plus a unique one.
          if (page == 1) {
            return [
              txMap(amount: '10.00', type: 'EXPENSE', txId: 'dup'),
              txMap(amount: '20.00', type: 'EXPENSE', txId: 'uniq1'),
            ];
          }
          return [
            txMap(amount: '10.00', type: 'EXPENSE', txId: 'dup'), // duplicate
            txMap(amount: '30.00', type: 'EXPENSE', txId: 'uniq2'),
          ];
        }
        return null;
      });

      final collected = <ParsedTransaction>[];
      final events = await SmsScanner()
          .scanInbox(pageSize: 2, onTransaction: collected.add)
          .toList();

      // dup appears twice across pages but is counted once. 3 distinct found.
      expect(events.last.found, 3);
      expect(collected.map((t) => t.transactionId).toSet(),
          {'dup', 'uniq1', 'uniq2'});
      expect(collected, hasLength(3));
    });

    test('UPI reference dedup collapses same RRN within the 3-min window',
        () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'readInbox') {
          // One page of two rows, then empty.
          return call.arguments['sinceEpochMillis'] == null
              ? [inboxRow(1000), inboxRow(1000)]
              : <Object?>[];
        }
        if (call.method == 'parseBatch') {
          // Same 12-digit reference + amount + type, 1 minute apart, but
          // DIFFERENT transactionIds (so only the UPI rule can catch it).
          return [
            txMap(
              amount: '500.00',
              type: 'EXPENSE',
              txId: 'id-A',
              reference: '123456789012',
              accountLast4: '1111',
              timestamp: 1700000000000,
            ),
            txMap(
              amount: '500.00',
              type: 'EXPENSE',
              txId: 'id-B',
              reference: '123456789012',
              accountLast4: '1111',
              timestamp: 1700000000000 + 60 * 1000, // +1 min
            ),
          ];
        }
        return null;
      });

      final events = await SmsScanner().scanInbox(pageSize: 5).toList();
      expect(events.last.found, 1); // second collapsed as UPI duplicate
    });

    test('progress counts are correct across multiple pages', () async {
      var page = 0;
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'readInbox') {
          page++;
          if (page == 1) return [inboxRow(1000), inboxRow(2000)];
          if (page == 2) return [inboxRow(3000), inboxRow(4000)];
          return <Object?>[];
        }
        if (call.method == 'parseBatch') {
          // One transaction parsed per page (the other row was unparseable).
          return [txMap(amount: '1.00', type: 'EXPENSE', txId: 'p$page')];
        }
        return null;
      });

      final events =
          await SmsScanner().scanInbox(pageSize: 2).toList();

      final pageEvents = events.where((e) => !e.done).toList();
      expect(pageEvents, hasLength(2));
      expect(pageEvents[0].processed, 2); // first page read 2 rows
      expect(pageEvents[0].found, 1);
      expect(pageEvents[1].processed, 4); // cumulative
      expect(pageEvents[1].found, 2);
      expect(events.last.done, isTrue);
      expect(events.last.processed, 4);
      expect(events.last.found, 2);
    });
  });
}
