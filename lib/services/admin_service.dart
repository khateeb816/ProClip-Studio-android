import 'package:cloud_firestore/cloud_firestore.dart';
import '../models/subscription_pricing.dart';

class AdminService {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  // ==================== USER MANAGEMENT ====================

  // Get all users from Firestore
  Future<List<Map<String, dynamic>>> getAllUsers() async {
    try {
      final snapshot = await _firestore
          .collection('users')
          .orderBy('createdAt', descending: true)
          .get();

      return snapshot.docs.map((doc) {
        final data = doc.data();
        data['id'] = doc.id; // Include document ID
        return data;
      }).toList();
    } catch (e) {
      print('Error getting all users: $e');
      return [];
    }
  }

  // Update user role
  Future<void> updateUserRole(String userId, String role) async {
    try {
      await _firestore.collection('users').doc(userId).update({
        'role': role,
      });
    } catch (e) {
      throw 'Failed to update user role: $e';
    }
  }

  // Update subscription status
  Future<void> updateSubscriptionStatus({
    required String userId,
    required String status,
    String? plan,
    DateTime? expiry,
  }) async {
    try {
      final updates = <String, dynamic>{
        'subscriptionStatus': status,
        'subscriptionPlan': plan,
        'subscriptionExpiry': expiry != null ? Timestamp.fromDate(expiry) : null,
      };

      await _firestore.collection('users').doc(userId).update(updates);
    } catch (e) {
      throw 'Failed to update subscription: $e';
    }
  }

  // Toggle user active status
  Future<void> toggleUserStatus(String userId, bool isActive) async {
    try {
      await _firestore.collection('users').doc(userId).update({
        'isActive': isActive,
      });
    } catch (e) {
      throw 'Failed to toggle user status: $e';
    }
  }

  // Delete user
  Future<void> deleteUser(String userId) async {
    try {
      await _firestore.collection('users').doc(userId).delete();
    } catch (e) {
      throw 'Failed to delete user: $e';
    }
  }

  // Get user statistics
  Future<Map<String, int>> getUserStats() async {
    try {
      final snapshot = await _firestore.collection('users').get();
      
      int totalUsers = snapshot.docs.length;
      int adminCount = 0;
      int freeUsers = 0;
      int premiumUsers = 0;
      int activeUsers = 0;

      for (var doc in snapshot.docs) {
        final data = doc.data();
        
        if (data['role'] == 'admin') adminCount++;
        if (data['subscriptionStatus'] == 'free') freeUsers++;
        if (data['subscriptionStatus'] == 'premium') premiumUsers++;
        if (data['isActive'] == true) activeUsers++;
      }

      return {
        'total': totalUsers,
        'admins': adminCount,
        'free': freeUsers,
        'premium': premiumUsers,
        'active': activeUsers,
      };
    } catch (e) {
      print('Error getting user stats: $e');
      return {
        'total': 0,
        'admins': 0,
        'free': 0,
        'premium': 0,
        'active': 0,
      };
    }
  }

  // ==================== PRICING MANAGEMENT ====================

  // Get subscription pricing
  Future<SubscriptionPricing> getSubscriptionPricing() async {
    try {
      final doc = await _firestore
          .collection('appConfig')
          .doc('subscriptionPricing')
          .get(const GetOptions(source: Source.server));

      if (doc.exists && doc.data() != null) {
        return SubscriptionPricing.fromFirestore(doc.data()!);
      } else {
        // Return default pricing if not set
        return SubscriptionPricing.defaultPricing();
      }
    } catch (e) {
      print('Error getting subscription pricing: $e');
      return SubscriptionPricing.defaultPricing();
    }
  }

  // Update subscription pricing
  Future<void> updateSubscriptionPricing(SubscriptionPricing pricing) async {
    try {
      await _firestore
          .collection('appConfig')
          .doc('subscriptionPricing')
          .set(pricing.toFirestore());
    } catch (e) {
      throw 'Failed to update pricing: $e';
    }
  }

  // Update individual prices (convenience methods)
  Future<void> updateWeeklyPrice(double price) async {
    try {
      final current = await getSubscriptionPricing();
      final updated = current.copyWith(weeklyPrice: price);
      await updateSubscriptionPricing(updated);
    } catch (e) {
      throw 'Failed to update weekly price: $e';
    }
  }

  Future<void> updateMonthlyPrice(double price) async {
    try {
      final current = await getSubscriptionPricing();
      final updated = current.copyWith(monthlyPrice: price);
      await updateSubscriptionPricing(updated);
    } catch (e) {
      throw 'Failed to update monthly price: $e';
    }
  }

  Future<void> updateYearlyPrice(double price) async {
    try {
      final current = await getSubscriptionPricing();
      final updated = current.copyWith(yearlyPrice: price);
      await updateSubscriptionPricing(updated);
    } catch (e) {
      throw 'Failed to update yearly price: $e';
    }
  }
}
