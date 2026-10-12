class WalletModel {
  const WalletModel({
    required this.balance,
    required this.currency,
    required this.frozen,
  });

  factory WalletModel.fromJson(Map<String, dynamic> map) {
    final data = map;
    return WalletModel(
      balance: (data['balance'] as num).toDouble(),
      currency: data['currency'] as String? ?? 'USD',
      frozen: data['frozen'] as bool? ?? false,
    );
  }

  final double balance;
  final String currency;
  final bool frozen;
}
