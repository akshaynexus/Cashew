import 'package:pdfrx/pdfrx.dart';

/// Thin, platform-touching wrapper around `pdfrx` for extracting plain text
/// from a PDF file (including password-protected statements).
///
/// This is the ONLY part of the PDF pipeline that touches platform/native
/// code. Keeping it isolated lets all parsing logic stay pure and
/// unit-testable against extracted strings.
class PdfTextExtractor {
  const PdfTextExtractor();

  /// Extracts all text from the PDF at [filePath], concatenating pages with
  /// newlines. If [password] is supplied it is used for encrypted PDFs.
  ///
  /// Throws if the PDF cannot be opened (e.g. wrong/missing password).
  Future<String> extractText(String filePath, {String? password}) async {
    final document = await PdfDocument.openFile(
      filePath,
      passwordProvider: password == null ? null : () => password,
      // If a password is provided, don't waste the first attempt on empty.
      firstAttemptByEmptyPassword: password == null,
    );
    try {
      final buffer = StringBuffer();
      for (final page in document.pages) {
        final pageText = await page.loadText();
        buffer.writeln(pageText.fullText);
      }
      return buffer.toString();
    } finally {
      document.dispose();
    }
  }
}
