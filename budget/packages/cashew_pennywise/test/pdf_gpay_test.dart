import 'package:cashew_pennywise/src/parsed_transaction.dart';
import 'package:cashew_pennywise/src/pdf/gpay_pdf_parser.dart';
import 'package:cashew_pennywise/src/pdf/pdf_statement_parser.dart';
import 'package:flutter_test/flutter_test.dart';

/// Computes the expected UTC instant for an IST wall-clock date, mirroring the
/// Kotlin test's `epochForIstDate("dd MMM, yyyy hh:mm a")`.
DateTime istEpoch(int y, int mo, int d, int h, int mi) =>
    istDateTime(y, mo, d, h, mi);

void main() {
  final parser = GPayPdfParser();

  // Fixture: each transaction is preceded by a date/year/time triplet on its
  // own lines (the separate-line-date format from GPayPdfParserTest.kt).
  const statementText = '''
Google Pay Statement
01 Sep,
2025
03:02 PM
Paid to Starbucks
₹450
UPI Transaction ID: 123456789012
Paid by HDFC Bank 1234
02 Sep,
2025
11:30 AM
Received from Alice
₹2,000
UPI Transaction ID: 223456789012
Paid to HDFC Bank 1234
03 Sep,
2025
07:45 PM
Paid to Amazon
₹1,250.50
UPI Transaction ID: 323456789012
Paid by HDFC Bank 1234''';

  // Table layout: date+anchor share a line, time on the next line.
  const tableLayoutStatementText = '''
Transaction statement
Date & time               Transaction details                                      Amount

15 Oct, 2025              Paid to SAMPLE MERCHANT A                               ₹12.34
11:08 AM                  UPI Transaction ID: 123456789012
                               Paid by Example Bank 1234

16 Oct, 2025              Received from SAMPLE SENDER                            ₹567.89
09:41 AM                  UPI Transaction ID: 223456789012
                               Paid to Example Bank 1234

16 Oct, 2025              Paid to SAMPLE MERCHANT B                                ₹42.00
11:13 AM                  UPI Transaction ID: 323456789012
                               Paid by Example Bank 1234''';

  test('canHandle recognises the GPay statement', () {
    expect(parser.canHandle(statementText), isTrue);
  });

  test('parses all three transactions', () {
    expect(parser.parse(statementText).length, 3);
  });

  test('each transaction gets its own timestamp (issue 250 regression)', () {
    final txs = parser.parse(statementText);
    expect(txs.length, 3);

    expect(txs[0].timestamp, istEpoch(2025, 9, 1, 15, 2));
    expect(txs[1].timestamp, istEpoch(2025, 9, 2, 11, 30));
    expect(txs[2].timestamp, istEpoch(2025, 9, 3, 19, 45));
  });

  test('last transaction does not fall back to current time', () {
    final txs = parser.parse(statementText);
    final last = txs.last.timestamp;
    final diff = DateTime.now().difference(last).abs();
    expect(diff.inHours, greaterThan(24));
  });

  test('middle transaction does not borrow next transaction date', () {
    final txs = parser.parse(statementText);
    expect(txs[1].timestamp, istEpoch(2025, 9, 2, 11, 30));
    expect(txs[1].timestamp, isNot(istEpoch(2025, 9, 3, 19, 45)));
  });

  test('merchant, type, amount and account extracted correctly', () {
    final txs = parser.parse(statementText);

    expect(txs[0].merchant, 'Starbucks');
    expect(txs[0].type, ParsedTransactionType.expense);
    expect(txs[0].amount, '450');
    expect(txs[0].accountLast4, '1234');
    expect(txs[0].reference, '123456789012');
    expect(txs[0].bankName, 'HDFC Bank');
    expect(txs[0].sender, 'GPay PDF');
    expect(txs[0].currency, 'INR');

    expect(txs[1].merchant, 'Alice');
    expect(txs[1].type, ParsedTransactionType.income);
    expect(txs[1].amount, '2000');

    expect(txs[2].merchant, 'Amazon');
    expect(txs[2].type, ParsedTransactionType.expense);
    expect(txs[2].amount, '1250.50');
  });

  test('parses table layout extracted from Google Pay PDF', () {
    final txs = parser.parse(tableLayoutStatementText);
    expect(txs.length, 3);

    expect(txs[0].merchant, 'SAMPLE MERCHANT A');
    expect(txs[0].type, ParsedTransactionType.expense);
    expect(txs[0].amount, '12.34');
    expect(txs[0].reference, '123456789012');
    expect(txs[0].accountLast4, '1234');
    expect(txs[0].timestamp, istEpoch(2025, 10, 15, 11, 8));

    expect(txs[1].merchant, 'SAMPLE SENDER');
    expect(txs[1].type, ParsedTransactionType.income);
    expect(txs[1].amount, '567.89');
    expect(txs[1].reference, '223456789012');
    expect(txs[1].timestamp, istEpoch(2025, 10, 16, 9, 41));

    expect(txs[2].merchant, 'SAMPLE MERCHANT B');
    expect(txs[2].type, ParsedTransactionType.expense);
    expect(txs[2].amount, '42.00');
    expect(txs[2].reference, '323456789012');
    expect(txs[2].timestamp, istEpoch(2025, 10, 16, 11, 13));
  });

  test('transactionId is stable and deterministic', () {
    final a = parser.parse(statementText);
    final b = parser.parse(statementText);
    expect(a[0].transactionId, b[0].transactionId);
    expect(a[0].transactionId, isNot(a[1].transactionId));
  });
}
