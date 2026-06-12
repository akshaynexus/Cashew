import '../parsed_transaction.dart';
import 'pdf_statement_parser_factory.dart';
import 'pdf_text_extractor.dart';

/// End-to-end convenience entry point: extract text from a PDF statement, then
/// dispatch it to the matching parser via [PdfStatementParserFactory].
class StatementImporter {
  final PdfTextExtractor _extractor;

  const StatementImporter({PdfTextExtractor extractor = const PdfTextExtractor()})
      : _extractor = extractor;

  /// Imports the PDF statement at [filePath], optionally decrypting with
  /// [password]. Returns the parsed transactions, or an empty list if no
  /// parser recognises the statement format.
  Future<List<ParsedTransaction>> importStatement(
    String filePath, {
    String? password,
  }) async {
    final text = await _extractor.extractText(filePath, password: password);
    return importFromText(text);
  }

  /// Parses already-extracted statement [text] (pure, no I/O). Returns an empty
  /// list when no parser matches.
  List<ParsedTransaction> importFromText(String text) {
    final parser = PdfStatementParserFactory.getParser(text);
    if (parser == null) return const [];
    return parser.parse(text);
  }
}
