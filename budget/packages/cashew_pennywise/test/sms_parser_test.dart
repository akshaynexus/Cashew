import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:cashew_pennywise/cashew_pennywise.dart';

/// Unit tests for the Dart side of the bridge. The Kotlin parser itself is
/// exercised on-device; here we mock the channel to lock down the codec
/// contract (argument shape out, ParsedTransaction.fromMap in).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('cashew_pennywise/parser');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test('parse maps a parser-core result into ParsedTransaction', () async {
    late MethodCall captured;
    messenger.setMockMethodCallHandler(channel, (call) async {
      captured = call;
      return <String, Object?>{
        'amount': '450.00',
        'type': 'EXPENSE',
        'merchant': 'Starbucks',
        'reference': '123456789012',
        'accountLast4': '4567',
        'balance': '25000.75',
        'creditLimit': null,
        'smsBody': 'Spent Rs.450 ...',
        'sender': 'HDFCBK',
        'timestamp': 1692345600000,
        'bankName': 'HDFC Bank',
        'transactionId': 'abc123',
        'isFromCard': true,
        'currency': 'INR',
        'fromAccount': null,
        'toAccount': null,
      };
    });

    final parser = SmsParser();
    final result = await parser.parse(RawMessage(
      sender: 'HDFCBK',
      body: 'Spent Rs.450 ...',
      timestamp: DateTime.fromMillisecondsSinceEpoch(1692345600000),
    ));

    expect(captured.method, 'parse');
    expect(captured.arguments['sender'], 'HDFCBK');
    expect(captured.arguments['timestamp'], 1692345600000);

    expect(result, isNotNull);
    expect(result!.type, ParsedTransactionType.expense);
    expect(result.merchant, 'Starbucks');
    expect(result.accountLast4, '4567');
    expect(result.isFromCard, true);
    expect(result.signedAmount, -450.0); // expense -> negative
  });

  test('parse returns null when no parser handled the message', () async {
    messenger.setMockMethodCallHandler(channel, (call) async => null);
    final result = await SmsParser().parse(RawMessage(
      sender: 'PROMO',
      body: 'Win a prize!',
      timestamp: DateTime(2024),
    ));
    expect(result, isNull);
  });

  test('parseBatch drops unparseable entries and parses the rest', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'parseBatch');
      final messages = call.arguments['messages'] as List;
      expect(messages.length, 2);
      // Simulate: only one of the two parsed.
      return [
        {
          'amount': '2000.00',
          'type': 'INCOME',
          'sender': 'HDFCBK',
          'smsBody': 'credited',
          'timestamp': 1692345600000,
          'bankName': 'HDFC Bank',
          'transactionId': 'x',
          'isFromCard': false,
          'currency': 'INR',
        }
      ];
    });

    final results = await SmsParser().parseBatch([
      RawMessage(sender: 'HDFCBK', body: 'credited', timestamp: DateTime(2024)),
      RawMessage(sender: 'PROMO', body: 'spam', timestamp: DateTime(2024)),
    ]);

    expect(results, hasLength(1));
    expect(results.first.isIncome, true);
    expect(results.first.signedAmount, 2000.0);
  });

  test('ping returns the parser count', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'ping');
      return 128;
    });
    expect(await SmsParser().parserCount(), 128);
  });
}
