/// cashew_pennywise
/// ----------------
/// Bridges PennyWise AI's parsers into Cashew.
///
/// - [SmsParser]: wraps the vendored pure-Kotlin parser-core (120-bank SMS
///   parser) over a MethodChannel. Android only.
/// - SMS capture: [SmsScanner] (inbox-scan worker port), [SmsInbox],
///   [SmsLiveStream], [SmsPermissions]. Android only.
/// - PDF statement import (GPay/PhonePe): [StatementImporter] and friends — a
///   pure-Dart port, cross-platform.
library cashew_pennywise;

// Shared contract.
export 'src/parsed_transaction.dart';

// SMS parsing + capture (Android).
export 'src/sms_parser.dart';
export 'src/sms_permissions.dart';
export 'src/sms_inbox.dart';
export 'src/sms_live.dart';
export 'src/sms_scanner.dart';
export 'src/notification_capture.dart';

// Capture logic (dedup + bank-balance reconciliation) — pure, cross-platform.
export 'src/capture/deduplicator.dart';
export 'src/capture/balance_reconciler.dart';
export 'src/capture/transaction_enricher.dart';

// PDF statement import (cross-platform).
export 'src/pdf/pdf_statement_parser.dart';
export 'src/pdf/gpay_pdf_parser.dart';
export 'src/pdf/phonepe_pdf_parser.dart';
export 'src/pdf/pdf_statement_parser_factory.dart';
export 'src/pdf/pdf_text_extractor.dart';
export 'src/pdf/statement_importer.dart';
