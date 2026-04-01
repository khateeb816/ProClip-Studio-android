import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import '../services/admin_service.dart';
import '../services/auth_service.dart';
import '../models/subscription_pricing.dart';

class PlansScreen extends StatefulWidget {
  const PlansScreen({super.key});

  @override
  State<PlansScreen> createState() => _PlansScreenState();
}

class _PlansScreenState extends State<PlansScreen> {
  final AdminService _adminService = AdminService();
  final AuthService _authService = AuthService();
  bool _isLoading = true;
  SubscriptionPricing? _pricing;
  String? _selectedPlan;

  @override
  void initState() {
    super.initState();
    _loadPricing();
  }

  Future<void> _loadPricing() async {
    try {
      final pricing = await _adminService.getSubscriptionPricing();
      if (mounted) {
        setState(() {
          _pricing = pricing;
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to load plans: $e')),
        );
      }
    }
  }

  Future<void> _contactForUpgrade() async {
    if (_selectedPlan == null) return;
    
    final user = _authService.currentUser;
    final email = user?.email ?? 'Unknown Email';
    final userId = user?.uid ?? 'Unknown ID';
    
    final message = "I want to upgrade with $_selectedPlan plan. \nMy Email is $email and userid is $userId";
    final encodedMessage = Uri.encodeComponent(message);

    final Uri url = Uri.parse('https://wa.me/923165451573?text=$encodedMessage');
    if (!await launchUrl(url, mode: LaunchMode.externalApplication)) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not launch WhatsApp')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF121212),
      appBar: AppBar(
        title: const Text("Upgrade Plan"),
        centerTitle: true,
        backgroundColor: Colors.transparent,
        elevation: 0,
      ),
      body: _isLoading
          ? const Center(
              child: CircularProgressIndicator(
                valueColor: AlwaysStoppedAnimation<Color>(Colors.cyanAccent),
              ),
            )
          : SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: Column(
                children: [
                  const Text(
                    "Choose Your Plan",
                    style: TextStyle(
                      fontSize: 28,
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    "Unlock premium features and remove limits.",
                    style: TextStyle(
                      fontSize: 16,
                      color: Colors.grey[400],
                    ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 32),
                  if (_pricing != null) ...[
                    _buildPlanCard(
                      title: 'Weekly',
                      price: _pricing!.weeklyPrice,
                      currency: _pricing!.currency,
                      color: Colors.blueAccent,
                      icon: Icons.calendar_view_week,
                    ),
                    const SizedBox(height: 16),
                    _buildPlanCard(
                      title: 'Monthly',
                      price: _pricing!.monthlyPrice,
                      currency: _pricing!.currency,
                      color: Colors.purpleAccent,
                      icon: Icons.calendar_month,
                      isPopular: true,
                    ),
                    const SizedBox(height: 16),
                    _buildPlanCard(
                      title: 'Yearly',
                      price: _pricing!.yearlyPrice,
                      currency: _pricing!.currency,
                      color: Colors.amber,
                      icon: Icons.calendar_today,
                    ),
                  ],
                  if (_selectedPlan != null) ...[
                    const SizedBox(height: 48),
                    const Text(
                      "To upgrade, please confirm your plan via WhatsApp:",
                      style: TextStyle(
                        fontSize: 14,
                        color: Colors.white70,
                      ),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 16),
                    SizedBox(
                      width: double.infinity,
                      height: 56,
                      child: ElevatedButton.icon(
                        onPressed: _contactForUpgrade,
                        icon: const Icon(Icons.chat),
                        label: const Text(
                          'Contact to Upgrade',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF25D366),
                          foregroundColor: Colors.white,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(16),
                          ),
                          elevation: 4,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
    );
  }

  Widget _buildPlanCard({
    required String title,
    required double price,
    required String currency,
    required Color color,
    required IconData icon,
    bool isPopular = false,
  }) {
    final isSelected = _selectedPlan == title;
    
    return GestureDetector(
      onTap: () {
        setState(() {
          _selectedPlan = title;
        });
      },
      child: Container(
        decoration: BoxDecoration(
          color: Colors.grey[900],
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: isSelected ? Colors.cyanAccent : (isPopular ? color : Colors.grey.withValues(alpha: 0.2)),
            width: isSelected ? 3 : (isPopular ? 2 : 1),
          ),
          boxShadow: isSelected
              ? [
                  BoxShadow(
                    color: Colors.cyanAccent.withValues(alpha: 0.4),
                    blurRadius: 15,
                    spreadRadius: 2,
                  )
                ]
              : (isPopular
                  ? [
                      BoxShadow(
                        color: color.withValues(alpha: 0.2),
                        blurRadius: 10,
                        spreadRadius: 2,
                      )
                    ]
                  : null),
        ),
        child: Stack(
          children: [
          Padding(
            padding: const EdgeInsets.all(24),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(icon, color: color, size: 32),
                ),
                const SizedBox(width: 20),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: const TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                          color: Colors.white,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '$currency ${price.toStringAsFixed(0)}',
                        style: TextStyle(
                          fontSize: 24,
                          fontWeight: FontWeight.bold,
                          color: color,
                        ),
                      ),
                    ],
                  ),
                ),
                if (isSelected)
                  const Icon(Icons.check_circle, color: Colors.cyanAccent, size: 28),
              ],
            ),
          ),
          if (isPopular)
            Positioned(
              top: 0,
              right: 20,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
                  color: color,
                  borderRadius: const BorderRadius.only(
                    bottomLeft: Radius.circular(8),
                    bottomRight: Radius.circular(8),
                  ),
                ),
                child: const Text(
                  'POPULAR',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                  ),
                ),
              ),
            ),
        ],
      ),
    ),
   );
  }
}
