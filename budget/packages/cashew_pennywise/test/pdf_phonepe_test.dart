import 'package:cashew_pennywise/src/parsed_transaction.dart';
import 'package:cashew_pennywise/src/pdf/pdf_statement_parser.dart';
import 'package:cashew_pennywise/src/pdf/pdf_statement_parser_factory.dart';
import 'package:cashew_pennywise/src/pdf/phonepe_pdf_parser.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final parser = PhonePePdfParser();

  // Representative PhonePe export: blocks split on DEBIT/CREDIT, with merchant,
  // amount, date and a Transaction ID / UTR per block.
  const statementText = '''
PhonePe Transaction Statement
DEBIT
Paid to Coffee Shop
₹450.00
Sep 01, 2025
Transaction ID: T2509011234567890
CREDIT
Received from Bob
₹2,000
02 Sep, 2025
UTR No: 998877665544
DEBIT
Sent to Amazon
₹1,250.50
03 Sep, 2025
Transaction ID: T2509031234567890''';

  test('canHandle recognises the PhonePe statement', () {
    expect(parser.canHandle(statementText), isTrue);
  });

  test('factory selects the PhonePe parser', () {
    final selected = PdfStatementParserFactory.getParser(statementText);
    expect(selected, isA<PhonePePdfParser>());
  });

  test('parses all three transactions', () {
    expect(parser.parse(statementText).length, 3);
  });

  test('extracts type, amount, merchant and reference', () {
    final txs = parser.parse(statementText);

    expect(txs[0].type, ParsedTransactionType.expense);
    expect(txs[0].amount, '450.00');
    expect(txs[0].merchant, 'Coffee Shop');
    expect(txs[0].reference, 'T2509011234567890');
    expect(txs[0].sender, 'PhonePe PDF');
    expect(txs[0].bankName, 'PhonePe');
    expect(txs[0].currency, 'INR');

    expect(txs[1].type, ParsedTransactionType.income);
    expect(txs[1].amount, '2000');
    expect(txs[1].merchant, 'Bob');
    expect(txs[1].reference, '998877665544');

    expect(txs[2].type, ParsedTransactionType.expense);
    expect(txs[2].amount, '1250.50');
    expect(txs[2].merchant, 'Amazon');
  });

  test('extracts IST date-only timestamps', () {
    final txs = parser.parse(statementText);
    // "Sep 01, 2025" (MMM dd, yyyy) and "02 Sep, 2025" (dd MMM, yyyy).
    expect(txs[0].timestamp, istDateTime(2025, 9, 1));
    expect(txs[1].timestamp, istDateTime(2025, 9, 2));
    expect(txs[2].timestamp, istDateTime(2025, 9, 3));
  });

  test('transactionId is stable and unique per block', () {
    final a = parser.parse(statementText);
    final b = parser.parse(statementText);
    expect(a[0].transactionId, b[0].transactionId);
    expect(a[0].transactionId, isNot(a[2].transactionId));
  });

  test('GPay parser does not claim PhonePe statements', () {
    expect(PdfStatementParserFactory.parsers.first.canHandle(statementText),
        isFalse);
  });
}
