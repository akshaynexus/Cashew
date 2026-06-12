import 'gpay_pdf_parser.dart';
import 'pdf_statement_parser.dart';
import 'phonepe_pdf_parser.dart';

/// Selects the appropriate PDF statement parser for already-extracted text.
///
/// Mirrors PennyWise's `PdfParserFactory`: parsers are tried in order (GPay,
/// then PhonePe) and the first whose `canHandle` matches wins.
class PdfStatementParserFactory {
  PdfStatementParserFactory._();

  /// The parsers, in priority order.
  static final List<PdfStatementParser> parsers = [
    GPayPdfParser(),
    PhonePePdfParser(),
  ];

  /// Returns the first parser that can handle [text], or `null` if none match.
  static PdfStatementParser? getParser(String text) {
    for (final parser in parsers) {
      if (parser.canHandle(text)) return parser;
    }
    return null;
  }
}
