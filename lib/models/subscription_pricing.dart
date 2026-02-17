import 'package:cloud_firestore/cloud_firestore.dart';

class SubscriptionPricing {
  final double weeklyPrice;
  final double monthlyPrice;
  final double yearlyPrice;
  final String currency;
  final DateTime? lastUpdated;

  SubscriptionPricing({
    required this.weeklyPrice,
    required this.monthlyPrice,
    required this.yearlyPrice,
    required this.currency,
    this.lastUpdated,
  });

  // Create from Firestore document
  factory SubscriptionPricing.fromFirestore(Map<String, dynamic> data) {
    return SubscriptionPricing(
      weeklyPrice: (data['weeklyPrice'] as num?)?.toDouble() ?? 0.0,
      monthlyPrice: (data['monthlyPrice'] as num?)?.toDouble() ?? 0.0,
      yearlyPrice: (data['yearlyPrice'] as num?)?.toDouble() ?? 0.0,
      currency: data['currency'] as String? ?? 'USD',
      lastUpdated: (data['lastUpdated'] as Timestamp?)?.toDate(),
    );
  }

  // Convert to Firestore document
  Map<String, dynamic> toFirestore() {
    return {
      'weeklyPrice': weeklyPrice,
      'monthlyPrice': monthlyPrice,
      'yearlyPrice': yearlyPrice,
      'currency': currency,
      'lastUpdated': FieldValue.serverTimestamp(),
    };
  }

  // Create default pricing
  factory SubscriptionPricing.defaultPricing() {
    return SubscriptionPricing(
      weeklyPrice: 100.0,
      monthlyPrice: 300.0,
      yearlyPrice: 3000.0,
      currency: 'PKR',
    );
  }

  // Copy with method for updates
  SubscriptionPricing copyWith({
    double? weeklyPrice,
    double? monthlyPrice,
    double? yearlyPrice,
    String? currency,
    DateTime? lastUpdated,
  }) {
    return SubscriptionPricing(
      weeklyPrice: weeklyPrice ?? this.weeklyPrice,
      monthlyPrice: monthlyPrice ?? this.monthlyPrice,
      yearlyPrice: yearlyPrice ?? this.yearlyPrice,
      currency: currency ?? this.currency,
      lastUpdated: lastUpdated ?? this.lastUpdated,
    );
  }
}
