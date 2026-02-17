import 'dart:async';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../services/auth_service.dart';
import 'admin/admin_panel_screen.dart';

class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  final _authService = AuthService();
  bool _isLoading = false;
  Map<String, dynamic>? _userData;
  bool _isAdmin = false;
  StreamSubscription? _userSubscription;

  @override
  void initState() {
    super.initState();
    _initUserStream();
  }

  @override
  void dispose() {
    _userSubscription?.cancel();
    super.dispose();
  }

  void _initUserStream() {
    setState(() => _isLoading = true);
    _userSubscription = _authService.userStream().listen((snapshot) {
      if (snapshot.exists && snapshot.data() != null) {
        if (mounted) {
          setState(() {
            _userData = snapshot.data();
            _isAdmin = _userData?['role'] == 'admin';
            _isLoading = false;
          });
        }
      } else {
        if (mounted) setState(() => _isLoading = false);
      }
    }, onError: (e) {
      print('Error in user stream: $e');
      if (mounted) setState(() => _isLoading = false);
    });
  }

  Future<void> _signOut() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF1E1E1E),
        title: const Text("Sign Out?", style: TextStyle(color: Colors.white)),
        content: const Text(
          "Are you sure you want to sign out?",
          style: TextStyle(color: Colors.grey),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text("Cancel"),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: Colors.redAccent),
            child: const Text("Sign Out"),
          ),
        ],
      ),
    );

    if (confirmed == true && mounted) {
      setState(() => _isLoading = true);
      
      try {
        await _authService.signOut();
        // AuthWrapper will automatically navigate to LoginScreen
      } catch (e) {
        if (mounted) {
          setState(() => _isLoading = false);
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Sign out failed: $e'),
              backgroundColor: Colors.redAccent,
            ),
          );
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final user = _authService.currentUser;

    return Scaffold(
      backgroundColor: const Color(0xFF121212),
      appBar: AppBar(
        title: const Text("Profile"),
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
                  const SizedBox(height: 20),

                  // Profile Picture
                  Container(
                    width: 120,
                    height: 120,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(color: Colors.cyanAccent, width: 3),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.cyanAccent.withValues(alpha: 0.3),
                          blurRadius: 20,
                          spreadRadius: 5,
                        ),
                      ],
                    ),
                    child: ClipOval(
                      child: user?.photoURL != null
                          ? Image.network(
                              user!.photoURL!,
                              fit: BoxFit.cover,
                              errorBuilder: (context, error, stackTrace) {
                                return _buildInitialsAvatar(user);
                              },
                            )
                          : _buildInitialsAvatar(user),
                    ),
                  ),

                  const SizedBox(height: 24),

                  // Display Name
                  Text(
                    user?.displayName ?? 'User',
                    style: const TextStyle(
                      fontSize: 28,
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                    ),
                  ),

                  const SizedBox(height: 8),

                  // Email
                  Text(
                    user?.email ?? '',
                    style: TextStyle(
                      fontSize: 16,
                      color: Colors.grey[400],
                    ),
                  ),

                  const SizedBox(height: 12),

                  // Subscription Badge
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    decoration: BoxDecoration(
                      color: _getSubscriptionColor(),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          _getSubscriptionIcon(),
                          size: 16,
                          color: Colors.white,
                        ),
                        const SizedBox(width: 8),
                        Text(
                          _getSubscriptionText(),
                          style: const TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.bold,
                            color: Colors.white,
                          ),
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(height: 40),
                  
                  // Usage Statistics
                  Row(
                    children: [
                      _buildStatBox(
                        'Clips Exported',
                        '${_userData?['clipsExported'] ?? 0}',
                        Icons.movie_outlined,
                        Colors.blueAccent,
                      ),
                      const SizedBox(width: 16),
                      _buildStatBox(
                        'Clips Uploaded',
                        '${_userData?['clipsUploaded'] ?? 0}',
                        Icons.cloud_upload_outlined,
                        Colors.greenAccent,
                      ),
                    ],
                  ),

                  const SizedBox(height: 32),

                  // Account Info Card
                  Container(
                    padding: const EdgeInsets.all(20),
                    decoration: BoxDecoration(
                      color: Colors.grey[900],
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(
                        color: Colors.grey.withValues(alpha: 0.2),
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Account Information',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                            color: Colors.cyanAccent,
                          ),
                        ),
                        const SizedBox(height: 20),
                        _buildInfoRow(
                          Icons.person_outline,
                          'Display Name',
                          user?.displayName ?? 'Not set',
                        ),
                        const Divider(height: 32, color: Colors.grey),
                        _buildInfoRow(
                          Icons.email_outlined,
                          'Email',
                          user?.email ?? 'Not set',
                        ),
                        const Divider(height: 32, color: Colors.grey),
                        _buildInfoRow(
                          Icons.verified_user_outlined,
                          'Email Verified',
                          user?.emailVerified == true ? 'Yes' : 'No',
                        ),
                        const Divider(height: 32, color: Colors.grey),
                        _buildInfoRow(
                          Icons.fingerprint,
                          'User ID',
                          user?.uid.substring(0, 8) ?? 'N/A',
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(height: 32),

                  // Admin Panel Button (only for admins)
                  if (_isAdmin) ...[
                    SizedBox(
                      width: double.infinity,
                      height: 56,
                      child: ElevatedButton.icon(
                        onPressed: () {
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => const AdminPanelScreen(),
                            ),
                          );
                        },
                        icon: const Icon(Icons.admin_panel_settings),
                        label: const Text(
                          'Admin Panel',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.deepPurpleAccent,
                          foregroundColor: Colors.white,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                          elevation: 0,
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                  ],

                  // Sign Out Button
                  SizedBox(
                    width: double.infinity,
                    height: 56,
                    child: ElevatedButton.icon(
                      onPressed: _signOut,
                      icon: const Icon(Icons.logout),
                      label: const Text(
                        'Sign Out',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.redAccent,
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                        elevation: 0,
                      ),
                    ),
                  ),

                  const SizedBox(height: 40),
                ],
              ),
            ),
    );
  }

  Widget _buildInitialsAvatar(User? user) {
    final initials = user?.displayName?.isNotEmpty == true
        ? user!.displayName!.substring(0, 1).toUpperCase()
        : user?.email?.substring(0, 1).toUpperCase() ?? 'U';

    return Container(
      color: Colors.cyanAccent,
      child: Center(
        child: Text(
          initials,
          style: const TextStyle(
            fontSize: 48,
            fontWeight: FontWeight.bold,
            color: Colors.black,
          ),
        ),
      ),
    );
  }

  Widget _buildStatBox(String label, String value, IconData icon, Color color) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 16),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: color.withValues(alpha: 0.2)),
        ),
        child: Column(
          children: [
            Icon(icon, color: color, size: 24),
            const SizedBox(height: 8),
            Text(
              value,
              style: const TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.bold,
                color: Colors.white,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              label,
              style: TextStyle(
                fontSize: 12,
                color: Colors.grey[400],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildInfoRow(IconData icon, String label, String value) {
    return Row(
      children: [
        Icon(icon, color: Colors.cyanAccent, size: 24),
        const SizedBox(width: 16),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: TextStyle(
                  fontSize: 12,
                  color: Colors.grey[400],
                ),
              ),
              const SizedBox(height: 4),
              Text(
                value,
                style: const TextStyle(
                  fontSize: 16,
                  color: Colors.white,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Color _getSubscriptionColor() {
    final status = _userData?['subscriptionStatus'] as String? ?? 'free';
    return status == 'premium' ? Colors.amber : Colors.grey;
  }

  IconData _getSubscriptionIcon() {
    final status = _userData?['subscriptionStatus'] as String? ?? 'free';
    return status == 'premium' ? Icons.star : Icons.person;
  }

  String _getSubscriptionText() {
    final status = _userData?['subscriptionStatus'] as String? ?? 'free';
    if (status == 'premium') {
      final plan = _userData?['subscriptionPlan'] as String?;
      if (plan != null) {
        return 'Premium - ${plan[0].toUpperCase()}${plan.substring(1)}';
      }
      return 'Premium';
    }
    return 'Free';
  }
}
