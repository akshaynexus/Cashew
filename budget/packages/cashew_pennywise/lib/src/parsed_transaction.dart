/// Mirrors PennyWise's `ParsedTransaction` (parser-core). This is the contract
/// the Kotlin parser emits and the Dart PDF parsers also produce, so both
/// capture paths funnel into one shape before mapping into Cashew's DB.
enum ParsedTransactionType {
  income,
  expense,
  credit,
  transfer,
  investment,
  balanceUpdate,
}

ParsedTransactionType _typeFromName(String? name) {
  switch (name) {
    case 'INCOME':
      return ParsedTransactionType.income;
    case 'EXPENSE':
      return ParsedTransactionType.expense;
    case 'CREDIT':
      return ParsedTransactionType.credit;
    case 'TRANSFER':
      return ParsedTransactionType.transfer;
    case 'INVESTMENT':
      return ParsedTransactionType.investment;
    case 'BALANCE_UPDATE':
      return ParsedTransactionType.balanceUpdate;
    default:
      return ParsedTransactionType.expense;
  }
}

class ParsedTransaction {
  /// Amount as the parser saw it, kept as a string to preserve precision.
  final String amount;
  final ParsedTransactionType type;
  final String? merchant;
  final String? reference;
  final String? accountLast4;
  final String? balance;
  final String? creditLimit;

  /// Original source text (SMS body, notification text, or PDF block).
  final String sourceText;
  final String sender;
  final DateTime timestamp;
  final String bankName;

  /// Stable id PennyWise uses for deduplication.
  final String transactionId;
  final bool isFromCard;
  final String currency;
  final String? fromAccount;
  final String? toAccount;

  const ParsedTransaction({
    required this.amount,
    required this.type,
    required this.merchant,
    required this.reference,
    required this.accountLast4,
    required this.balance,
    required this.creditLimit,
    required this.sourceText,
    required this.sender,
    required this.timestamp,
    required this.bankName,
    required this.transactionId,
    required this.isFromCard,
    required this.currency,
    required this.fromAccount,
    required this.toAccount,
  });

  /// Signed amount: negative for outflows, positive for inflows. Maps directly
  /// to Cashew's `Transaction.amount` sign convention.
  double get signedAmount {
    final value = double.tryParse(amount) ?? 0;
    final magnitude = value.abs();
    switch (type) {
      case ParsedTransactionType.income:
        return magnitude;
      case ParsedTransactionType.expense:
      case ParsedTransactionType.credit:
      case ParsedTransactionType.investment:
        return -magnitude;
      case ParsedTransactionType.transfer:
      case ParsedTransactionType.balanceUpdate:
        return value; // ambiguous direction — caller decides
    }
  }

  bool get isIncome => type == ParsedTransactionType.income;

  factory ParsedTransaction.fromMap(Map<dynamic, dynamic> map) {
    return ParsedTransaction(
      amount: map['amount'] as String? ?? '0',
      type: _typeFromName(map['type'] as String?),
      merchant: map['merchant'] as String?,
      reference: map['reference'] as String?,
      accountLast4: map['accountLast4'] as String?,
      balance: map['balance'] as String?,
      creditLimit: map['creditLimit'] as String?,
      sourceText: (map['smsBody'] ?? map['sourceText'] ?? '') as String,
      sender: map['sender'] as String? ?? '',
      timestamp: DateTime.fromMillisecondsSinceEpoch(
        (map['timestamp'] as num?)?.toInt() ?? 0,
      ),
      bankName: map['bankName'] as String? ?? '',
      transactionId: map['transactionId'] as String? ?? '',
      isFromCard: map['isFromCard'] as bool? ?? false,
      currency: map['currency'] as String? ?? 'INR',
      fromAccount: map['fromAccount'] as String?,
      toAccount: map['toAccount'] as String?,
    );
  }

  @override
  String toString() =>
      'ParsedTransaction($type $amount $currency, merchant=$merchant, '
      'bank=$bankName, last4=$accountLast4)';
}

/// An e-mandate / subscription detected in a bank SMS. Maps onto a Cashew
/// recurring (subscription) transaction.
class ParsedMandate {
  /// Recurring charge amount (string to preserve precision).
  final String amount;
  final String merchant;

  /// Unique Mandate Number, when the bank provides one. Best dedup key.
  final String? umn;

  /// Next deduction date, if the SMS stated one.
  final DateTime? nextDeductionDate;

  final String bankName;
  final String sender;
  final String sourceText;

  const ParsedMandate({
    required this.amount,
    required this.merchant,
    required this.umn,
    required this.nextDeductionDate,
    required this.bankName,
    required this.sender,
    required this.sourceText,
  });

  /// Stable id for dedup: prefer the UMN, else merchant+amount+sender.
  String get mandateId =>
      'mandate:${umn ?? '$merchant|$amount|$sender'}';

  factory ParsedMandate.fromMap(Map<dynamic, dynamic> map) {
    final ms = (map['nextDeductionEpochMillis'] as num?)?.toInt();
    return ParsedMandate(
      amount: map['amount'] as String? ?? '0',
      merchant: map['merchant'] as String? ?? 'Subscription',
      umn: map['umn'] as String?,
      nextDeductionDate:
          ms == null ? null : DateTime.fromMillisecondsSinceEpoch(ms),
      bankName: map['bankName'] as String? ?? '',
      sender: map['sender'] as String? ?? '',
      sourceText: (map['smsBody'] ?? map['sourceText'] ?? '') as String,
    );
  }

  @override
  String toString() =>
      'ParsedMandate($merchant $amount, umn=$umn, next=$nextDeductionDate)';
}

/// One raw message handed to the parser (SMS, or notification text).
class RawMessage {
  final String sender;
  final String body;
  final DateTime timestamp;

  const RawMessage({
    required this.sender,
    required this.body,
    required this.timestamp,
  });

  Map<String, Object?> toChannelMap() => {
        'sender': sender,
        'body': body,
        'timestamp': timestamp.millisecondsSinceEpoch,
      };
}
