import '../parsed_transaction.dart';

/// Contract for a PDF statement parser. Mirrors PennyWise's
/// `PdfStatementParser` Kotlin interface: parsers operate on text that has
/// ALREADY been extracted from the PDF, keeping the parsing logic pure and
/// unit-testable (extraction is isolated in `pdf_text_extractor.dart`).
abstract class PdfStatementParser {
  /// Returns true if this parser recognises the statement format.
  bool canHandle(String text);

  /// Parses the extracted text into [ParsedTransaction] objects.
  List<ParsedTransaction> parse(String text);
}

/// Indian Standard Time offset (UTC+5:30). PennyWise builds all statement
/// timestamps in IST; we replicate that explicitly here.
const Duration kIstOffset = Duration(hours: 5, minutes: 30);

/// Builds a UTC [DateTime] from IST wall-clock components.
///
/// The equivalent of constructing a `Date` with an IST [TimeZone] in Kotlin:
/// the resulting instant is the same absolute moment, expressed in UTC so it
/// round-trips through `millisecondsSinceEpoch` independent of device tz.
DateTime istDateTime(
  int year,
  int month,
  int day, [
  int hour = 0,
  int minute = 0,
  int second = 0,
]) {
  // Construct as UTC then subtract the IST offset to get the real instant.
  final asIfUtc = DateTime.utc(year, month, day, hour, minute, second);
  return asIfUtc.subtract(kIstOffset);
}

/// Deterministic 64-bit FNV-1a hash rendered as hex. Used to mint stable
/// `transactionId`s from `sender|amount|reference|timestamp`, mirroring
/// PennyWise's dedup intent without pulling in a crypto dependency.
String stableTransactionId(String input) {
  // FNV-1a 64-bit.
  var hash = 0xcbf29ce484222325;
  const prime = 0x100000001b3;
  const mask = 0xFFFFFFFFFFFFFFFF;
  for (final codeUnit in input.codeUnits) {
    hash ^= codeUnit;
    hash = (hash * prime) & mask;
  }
  return hash.toRadixString(16).padLeft(16, '0');
}

/// Three-letter English month names → month number (1-12).
const Map<String, int> kMonthAbbreviations = {
  'jan': 1,
  'feb': 2,
  'mar': 3,
  'apr': 4,
  'may': 5,
  'jun': 6,
  'jul': 7,
  'aug': 8,
  'sep': 9,
  'oct': 10,
  'nov': 11,
  'dec': 12,
};
