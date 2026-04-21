import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../../services/admin_service.dart';
import '../../models/subscription_pricing.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../../services/auth_service.dart';
import 'package:firebase_auth/firebase_auth.dart' as firebase_auth;

class AdminPanelScreen extends StatefulWidget {
  const AdminPanelScreen({super.key});

  @override
  State<AdminPanelScreen> createState() => _AdminPanelScreenState();
}

class _AdminPanelScreenState extends State<AdminPanelScreen> with SingleTickerProviderStateMixin {
  final _adminService = AdminService();
  final _authService = AuthService();
  late TabController _tabController;
  
  // Pricing controllers
  final _weeklyController = TextEditingController();
  final _monthlyController = TextEditingController();
  final _yearlyController = TextEditingController();
  final _currencyController = TextEditingController();
  
  // Announcement state
  final _announcementController = TextEditingController();
  DateTime? _announcementDeadline;
  Map<String, dynamic>? _currentAnnouncement;
  
  List<Map<String, dynamic>> _users = [];
  Map<String, int> _stats = {};
  SubscriptionPricing? _pricing;
  bool _isLoading = true;
  String _searchQuery = '';
  String _statusFilter = 'all'; // all, free, premium, admin
  
  // Debug info
  String? _currentUID;
  String? _currentRole;
  bool _isDebugVisible = false;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
    _currentUID = firebase_auth.FirebaseAuth.instance.currentUser?.uid;
    _loadData();
    _loadDebugInfo();
  }

  Future<void> _loadDebugInfo() async {
    final role = await _authService.getUserRole();
    if (mounted) {
      setState(() => _currentRole = role);
    }
  }

  @override
  void dispose() {
    _tabController.dispose();
    _weeklyController.dispose();
    _monthlyController.dispose();
    _yearlyController.dispose();
    _currencyController.dispose();
    _announcementController.dispose();
    super.dispose();
  }

  Future<void> _loadData() async {
    setState(() => _isLoading = true);
    
    try {
      final users = await _adminService.getAllUsers();
      final stats = await _adminService.getUserStats();
      final pricing = await _adminService.getSubscriptionPricing();
      final announcement = await _adminService.getAnnouncement();
      
      if (mounted) {
        setState(() {
          _users = users;
          _stats = stats;
          _pricing = pricing;
          _currentAnnouncement = announcement;
          
          // Update controllers if not currently focused to avoid jumping while typing
          _weeklyController.text = pricing.weeklyPrice.toString();
          _monthlyController.text = pricing.monthlyPrice.toString();
          _yearlyController.text = pricing.yearlyPrice.toString();
          _currencyController.text = pricing.currency;
          
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isLoading = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error loading data: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF121212),
      appBar: AppBar(
        title: const Text('Admin Dashboard', style: TextStyle(fontWeight: FontWeight.bold, letterSpacing: 1.2)),
        centerTitle: true,
        backgroundColor: Colors.transparent,
        elevation: 0,
        flexibleSpace: Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              colors: [Color(0xFF6A1B9A), Color(0xFF4A148C)],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
          ),
        ),
        bottom: TabBar(
          controller: _tabController,
          indicatorColor: Colors.cyanAccent,
          indicatorWeight: 3,
          labelColor: Colors.cyanAccent,
          unselectedLabelColor: Colors.grey[400],
          tabs: const [
            Tab(icon: Icon(Icons.people), text: 'Users'),
            Tab(icon: Icon(Icons.attach_money), text: 'Pricing'),
            Tab(icon: Icon(Icons.campaign), text: 'Announce'),
          ],
        ),
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator(color: Colors.cyanAccent))
          : TabBarView(
              controller: _tabController,
              children: [
                _buildUsersTab(),
                _buildPricingTab(),
                _buildAnnouncementsTab(),
              ],
            ),
    );
  }

  Widget _buildUsersTab() {
    final filteredUsers = _users.where((user) {
      // Status Filter
      final status = (user['subscriptionStatus'] as String? ?? 'free').toLowerCase();
      final role = (user['role'] as String? ?? 'user').toLowerCase();
      
      if (_statusFilter == 'free') {
        if (status == 'premium' || status == 'active') return false;
      }
      if (_statusFilter == 'premium' && (status != 'premium' && status != 'active')) return false;
      if (_statusFilter == 'admin' && role != 'admin') return false;

      // Search Query
      if (_searchQuery.isEmpty) return true;
      final name = (user['displayName'] as String? ?? '').toLowerCase();
      final email = (user['email'] as String? ?? '').toLowerCase();
      final id = (user['id'] as String? ?? '').toLowerCase();
      return name.contains(_searchQuery.toLowerCase()) || 
             email.contains(_searchQuery.toLowerCase()) ||
             id.contains(_searchQuery.toLowerCase());
    }).toList();

    return Column(
      children: [
        // Stats Cards
        Container(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Row(
            children: [
              Expanded(child: _buildStatCard('Total', _stats['total'] ?? 0, Colors.blue)),
              const SizedBox(width: 8),
              Expanded(child: _buildStatCard('Premium', _stats['premium'] ?? 0, Colors.amber)),
              const SizedBox(width: 8),
              Expanded(child: _buildStatCard('Free', _stats['free'] ?? 0, Colors.grey)),
            ],
          ),
        ),

        // Filter Chips
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            children: [
              _buildFilterChip('All', 'all', Icons.group),
              const SizedBox(width: 8),
              _buildFilterChip('Free', 'free', Icons.person_outline),
              const SizedBox(width: 8),
              _buildFilterChip('Premium', 'premium', Icons.star),
              const SizedBox(width: 8),
              _buildFilterChip('Admin', 'admin', Icons.admin_panel_settings),
            ],
          ),
        ),

        // Search Bar
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
          child: TextField(
            onChanged: (value) => setState(() => _searchQuery = value),
            style: const TextStyle(color: Colors.white),
            decoration: InputDecoration(
              hintText: 'Search by name, email or ID...',
              hintStyle: TextStyle(color: Colors.grey[400]),
              prefixIcon: const Icon(Icons.search, color: Colors.cyanAccent),
              filled: true,
              fillColor: Colors.grey[900],
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide.none,
              ),
              contentPadding: const EdgeInsets.symmetric(vertical: 0),
            ),
          ),
        ),

        // Users List
        Expanded(
          child: filteredUsers.isEmpty
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.search_off, size: 48, color: Colors.grey[600]),
                      const SizedBox(height: 16),
                      Text(
                        'No users found matching your criteria',
                        style: TextStyle(color: Colors.grey[400]),
                      ),
                    ],
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  itemCount: filteredUsers.length,
                  itemBuilder: (context, index) {
                    return _buildUserCard(filteredUsers[index]);
                  },
                ),
        ),
      ],
    );
  }

  Widget _buildFilterChip(String label, String value, IconData icon) {
    final isSelected = _statusFilter == value;
    return FilterChip(
      showCheckmark: false,
      avatar: Icon(
        icon, 
        size: 16, 
        color: isSelected ? Colors.black : Colors.cyanAccent
      ),
      label: Text(label),
      selected: isSelected,
      onSelected: (selected) {
        setState(() => _statusFilter = value);
      },
      selectedColor: Colors.cyanAccent,
      backgroundColor: Colors.grey[900],
      labelStyle: TextStyle(
        color: isSelected ? Colors.black : Colors.white,
        fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
        fontSize: 12,
      ),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: BorderSide(
          color: isSelected ? Colors.cyanAccent : Colors.grey.withValues(alpha: 0.3),
        ),
      ),
    );
  }

  Widget _buildStatCard(String label, int count, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 8),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [color.withValues(alpha: 0.15), color.withValues(alpha: 0.05)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: color.withValues(alpha: 0.3), width: 1.5),
        boxShadow: [
          BoxShadow(
            color: color.withValues(alpha: 0.05),
            blurRadius: 10,
            spreadRadius: 1,
          )
        ]
      ),
      child: Column(
        children: [
          Text(
            '$count',
            style: TextStyle(
              fontSize: 28,
              fontWeight: FontWeight.w900,
              color: color,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            label,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w500,
              color: Colors.grey[300],
              letterSpacing: 0.5,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildUserCard(Map<String, dynamic> user) {
    final isActive = user['isActive'] as bool? ?? true;
    final role = user['role'] as String? ?? 'user';
    final subscriptionStatus = user['subscriptionStatus'] as String? ?? 'free';
    final subscriptionPlan = user['subscriptionPlan'] as String?;
    final expiry = user['subscriptionExpiry'] as Timestamp?;
    
    // Determine if subscription is effectively active
    final isExpired = expiry != null && expiry.toDate().isBefore(DateTime.now());
    final isPremium = subscriptionStatus == 'premium' && !isExpired;

    // Badge styling based on plan/status
    Color badgeColor = Colors.grey;
    String badgeText = 'FREE';

    if (isPremium && subscriptionPlan != null) {
      if (subscriptionPlan == 'weekly') {
        badgeColor = Colors.teal;
        badgeText = 'WEEKLY';
      } else if (subscriptionPlan == 'monthly') {
        badgeColor = Colors.indigo;
        badgeText = 'MONTHLY';
      } else if (subscriptionPlan == 'yearly') {
        badgeColor = Colors.amber[700]!;
        badgeText = 'YEARLY';
      } else {
        badgeColor = Colors.amber;
        badgeText = 'PREMIUM';
      }
    } else if (subscriptionStatus == 'premium' && isExpired) {
      badgeColor = Colors.redAccent;
      badgeText = 'EXPIRED';
    }

    return Card(
      color: const Color(0xFF1A1A1A),
      elevation: 4,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: Colors.white.withValues(alpha: 0.05)),
      ),
      margin: const EdgeInsets.only(bottom: 16),
      child: Padding(
        padding: const EdgeInsets.all(8.0),
        child: ListTile(
          leading: Container(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: (isActive ? Colors.cyanAccent : Colors.redAccent).withValues(alpha: 0.3),
                  blurRadius: 8,
                  spreadRadius: 2,
                )
              ]
            ),
            child: GestureDetector(
              onTap: () {
                if (user['photoURL'] != null) {
                  _showFullScreenImage(user['photoURL'], user['displayName'] as String? ?? 'User');
                }
              },
              child: CircleAvatar(
                radius: 24,
                backgroundColor: isActive ? Colors.cyanAccent.withValues(alpha: 0.2) : Colors.redAccent.withValues(alpha: 0.2),
                child: user['photoURL'] != null
                    ? ClipOval(child: Image.network(user['photoURL'], fit: BoxFit.cover, width: 48, height: 48))
                    : Text(
                        (user['displayName'] as String? ?? 'U')[0].toUpperCase(),
                        style: TextStyle(color: isActive ? Colors.cyanAccent : Colors.redAccent, fontWeight: FontWeight.bold, fontSize: 20),
                      ),
              ),
            ),
          ),
        title: Row(
          children: [
            Expanded(
              child: Text(
                user['displayName'] as String? ?? 'Unknown',
                style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
              ),
            ),
            if (role == 'admin')
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: Colors.deepPurpleAccent,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Text(
                  'ADMIN',
                  style: TextStyle(fontSize: 10, color: Colors.white, fontWeight: FontWeight.bold),
                ),
              ),
          ],
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              user['email'] as String? ?? '',
              style: TextStyle(color: Colors.grey[400], fontSize: 12),
            ),
            const SizedBox(height: 2),
            SelectableText(
              'ID: ${user['id']}',
              style: TextStyle(color: Colors.cyanAccent.withValues(alpha: 0.7), fontSize: 10, fontFamily: 'monospace'),
            ),
            const SizedBox(height: 4),
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: badgeColor,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    badgeText,
                    style: const TextStyle(fontSize: 10, color: Colors.white, fontWeight: FontWeight.bold),
                  ),
                ),
                const SizedBox(width: 8),
                if (isPremium && expiry != null)
                  Text(
                    'Expires: ${DateFormat('MMM dd').format(expiry.toDate())}',
                    style: TextStyle(color: Colors.grey[500], fontSize: 10),
                  ),
                const Spacer(),
                Icon(
                  isActive ? Icons.check_circle : Icons.cancel,
                  size: 16,
                  color: isActive ? Colors.green : Colors.red,
                ),
              ],
            ),
          ],
        ),
        trailing: IconButton(
          icon: const Icon(Icons.edit, color: Colors.cyanAccent),
          onPressed: () => _showEditUserDialog(user),
        ),
      ),
    ),
  );
}

  Widget _buildPricingTab() {
    if (_pricing == null) {
      return const Center(child: Text('Loading pricing...', style: TextStyle(color: Colors.white)));
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Subscription Pricing',
            style: TextStyle(
              fontSize: 24,
              fontWeight: FontWeight.bold,
              color: Colors.white,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Configure subscription prices for all plans',
            style: TextStyle(color: Colors.grey[400]),
          ),
          const SizedBox(height: 32),

          _buildPriceField('Weekly Price', _weeklyController, Icons.calendar_today),
          const SizedBox(height: 16),
          _buildPriceField('Monthly Price', _monthlyController, Icons.calendar_month),
          const SizedBox(height: 16),
          _buildPriceField('Yearly Price', _yearlyController, Icons.calendar_view_month),
          const SizedBox(height: 16),
          _buildPriceField('Currency', _currencyController, Icons.attach_money, isNumber: false),

          const SizedBox(height: 32),

          if (_pricing!.lastUpdated != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 16),
              child: Text(
                'Last updated: ${DateFormat('MMM dd, yyyy HH:mm').format(_pricing!.lastUpdated!)}',
                style: TextStyle(color: Colors.grey[400], fontSize: 12),
              ),
            ),

          const SizedBox(height: 16),

          SizedBox(
            width: double.infinity,
            height: 56,
            child: ElevatedButton.icon(
              onPressed: () => _savePricing(
                _weeklyController.text,
                _monthlyController.text,
                _yearlyController.text,
                _currencyController.text,
              ),
              icon: const Icon(Icons.save),
              label: const Text(
                'Save Changes',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.green,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDebugRow(String label, String value) {
    return Row(
      children: [
        Text(label, style: const TextStyle(color: Colors.grey, fontSize: 12)),
        const SizedBox(width: 8),
        Expanded(
          child: SelectableText(
            value,
            style: const TextStyle(color: Colors.cyanAccent, fontSize: 12, fontFamily: 'monospace'),
          ),
        ),
      ],
    );
  }

  Widget _buildPriceField(String label, TextEditingController controller, IconData icon, {bool isNumber = true}) {
    return TextField(
      controller: controller,
      keyboardType: isNumber ? TextInputType.number : TextInputType.text,
      style: const TextStyle(color: Colors.white),
      decoration: InputDecoration(
        labelText: label,
        labelStyle: TextStyle(color: Colors.grey[400]),
        prefixIcon: Icon(icon, color: Colors.cyanAccent),
        filled: true,
        fillColor: Colors.grey[900],
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: Colors.grey.withValues(alpha: 0.2)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: Colors.cyanAccent, width: 2),
        ),
      ),
    );
  }

  Future<void> _savePricing(String weekly, String monthly, String yearly, String currency) async {
    try {
      final weeklyPrice = double.tryParse(weekly);
      final monthlyPrice = double.tryParse(monthly);
      final yearlyPrice = double.tryParse(yearly);

      if (weeklyPrice == null || monthlyPrice == null || yearlyPrice == null) {
        throw 'Invalid price values';
      }

      final newPricing = SubscriptionPricing(
        weeklyPrice: weeklyPrice,
        monthlyPrice: monthlyPrice,
        yearlyPrice: yearlyPrice,
        currency: currency,
      );

      await _adminService.updateSubscriptionPricing(newPricing);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Pricing updated successfully'), backgroundColor: Colors.green),
        );
        _loadData();
      }
    } catch (e) {
      if (mounted) {
        String errorMsg = e.toString();
        if (errorMsg.contains('permission-denied')) {
          errorMsg = 'Permission Denied: Ensure your account has the "admin" role and Firestore Security Rules are updated.';
        }
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(errorMsg),
            backgroundColor: Colors.red,
            duration: const Duration(seconds: 5),
            action: SnackBarAction(
              label: 'Setup Guide',
              textColor: Colors.white,
              onPressed: () {
                // You could show a dialog with setup instructions here
              },
            ),
          ),
        );
      }
    }
  }

  void _showFullScreenImage(String imageUrl, String userName) {
    showGeneralDialog(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'Close',
      barrierColor: Colors.black,
      transitionDuration: const Duration(milliseconds: 300),
      pageBuilder: (context, animation, secondaryAnimation) => Scaffold(
        backgroundColor: Colors.black,
        body: Stack(
          children: [
            Center(
              child: InteractiveViewer(
                boundaryMargin: const EdgeInsets.all(20),
                minScale: 0.5,
                maxScale: 5.0,
                child: SizedBox(
                  width: MediaQuery.of(context).size.width,
                  height: MediaQuery.of(context).size.height,
                  child: Image.network(
                    imageUrl,
                    fit: BoxFit.contain,
                    loadingBuilder: (context, child, loadingProgress) {
                      if (loadingProgress == null) return child;
                      return const Center(child: CircularProgressIndicator(color: Colors.cyanAccent));
                    },
                  ),
                ),
              ),
            ),
            SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.5),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Text(
                        userName,
                        style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close, color: Colors.white, size: 32),
                      onPressed: () => Navigator.pop(context),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showEditUserDialog(Map<String, dynamic> user) {
    showDialog(
      context: context,
      builder: (context) => _EditUserDialog(
        user: user,
        onSave: () {
          Navigator.pop(context);
          _loadData();
        },
      ),
    );
  }

  Widget _buildAnnouncementsTab() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Global Announcement',
            style: TextStyle(
              fontSize: 26,
              fontWeight: FontWeight.w900,
              color: Colors.white,
              letterSpacing: 1.2,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Create a pop-up announcement that will be displayed to all users on the Home Screen.',
            style: TextStyle(color: Colors.grey[400], fontSize: 14),
          ),
          const SizedBox(height: 32),
          
          if (_currentAnnouncement != null) ...[
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: Colors.cyanAccent.withValues(alpha: 0.05),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: Colors.cyanAccent.withValues(alpha: 0.3)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.campaign, color: Colors.cyanAccent),
                      const SizedBox(width: 8),
                      const Text(
                        'Active Announcement',
                        style: TextStyle(color: Colors.cyanAccent, fontWeight: FontWeight.bold, fontSize: 16),
                      ),
                      const Spacer(),
                      IconButton(
                        icon: const Icon(Icons.delete, color: Colors.redAccent),
                        onPressed: () async {
                          await _adminService.clearAnnouncement();
                          _loadData();
                          if (mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: Text('Announcement cleared!'), backgroundColor: Colors.green),
                            );
                          }
                        },
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Text(
                    _currentAnnouncement!['message'] ?? '',
                    style: const TextStyle(color: Colors.white, fontSize: 16),
                  ),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Icon(Icons.timer, color: Colors.grey[400], size: 16),
                      const SizedBox(width: 4),
                      Text(
                        'Deadline: ${DateFormat('MMM dd, yyyy HH:mm').format((_currentAnnouncement!['deadline'] as Timestamp).toDate())}',
                        style: TextStyle(color: Colors.grey[400], fontSize: 12),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 32),
          ],

          TextField(
            controller: _announcementController,
            maxLines: 4,
            style: const TextStyle(color: Colors.white),
            decoration: InputDecoration(
              labelText: 'Announcement Message',
              labelStyle: TextStyle(color: Colors.grey[400]),
              alignLabelWithHint: true,
              filled: true,
              fillColor: Colors.grey[900],
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(16),
                borderSide: BorderSide.none,
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(16),
                borderSide: const BorderSide(color: Colors.cyanAccent, width: 2),
              ),
            ),
          ),
          const SizedBox(height: 20),
          
          ListTile(
            tileColor: Colors.grey[900],
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            leading: const Icon(Icons.date_range, color: Colors.cyanAccent),
            title: Text(
              _announcementDeadline == null 
                  ? 'Set Expiration Deadline' 
                  : 'Deadline: ${DateFormat('MMM dd, yyyy HH:mm').format(_announcementDeadline!)}',
              style: const TextStyle(color: Colors.white),
            ),
            trailing: const Icon(Icons.chevron_right, color: Colors.grey),
            onTap: () async {
              final date = await showDatePicker(
                context: context,
                initialDate: DateTime.now().add(const Duration(days: 1)),
                firstDate: DateTime.now(),
                lastDate: DateTime.now().add(const Duration(days: 365)),
              );
              if (date != null && mounted) {
                final time = await showTimePicker(
                  context: context,
                  initialTime: TimeOfDay.now(),
                );
                if (time != null && mounted) {
                  setState(() {
                    _announcementDeadline = DateTime(
                      date.year, date.month, date.day, time.hour, time.minute
                    );
                  });
                }
              }
            },
          ),
          
          const SizedBox(height: 32),
          
          SizedBox(
            width: double.infinity,
            height: 56,
            child: ElevatedButton.icon(
              onPressed: () async {
                if (_announcementController.text.isEmpty) {
                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Message is required')));
                  return;
                }
                if (_announcementDeadline == null) {
                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Deadline is required')));
                  return;
                }
                
                await _adminService.setAnnouncement(_announcementController.text, _announcementDeadline!);
                _announcementController.clear();
                setState(() => _announcementDeadline = null);
                _loadData();
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Announcement Published!'), backgroundColor: Colors.green),
                  );
                }
              },
              icon: const Icon(Icons.send),
              label: const Text(
                'Publish Announcement',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.deepPurpleAccent,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                elevation: 8,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// Edit User Dialog
class _EditUserDialog extends StatefulWidget {
  final Map<String, dynamic> user;
  final VoidCallback onSave;

  const _EditUserDialog({required this.user, required this.onSave});

  @override
  State<_EditUserDialog> createState() => _EditUserDialogState();
}

class _EditUserDialogState extends State<_EditUserDialog> {
  final _adminService = AdminService();
  late String _role;
  late String _subscriptionStatus;
  late String? _subscriptionPlan;
  late bool _isActive;
  DateTime? _expiryDate;

  @override
  void initState() {
    super.initState();
    
    // Sanitize role
    final rawRole = (widget.user['role'] as String? ?? 'user').toLowerCase();
    _role = ['user', 'admin'].contains(rawRole) ? rawRole : 'user';
    
    // Sanitize subscription status
    final rawStatus = (widget.user['subscriptionStatus'] as String? ?? 'free').toLowerCase();
    // Handle cases where status might be 'active' or something else from older data
    if (rawStatus == 'active' || rawStatus == 'active') {
      _subscriptionStatus = 'premium';
    } else {
      _subscriptionStatus = ['free', 'premium'].contains(rawStatus) ? rawStatus : 'free';
    }
    
    // Sanitize subscription plan
    final rawPlan = (widget.user['subscriptionPlan'] as String?)?.toLowerCase();
    _subscriptionPlan = ['weekly', 'monthly', 'yearly'].contains(rawPlan) ? rawPlan : null;
    
    _isActive = widget.user['isActive'] as bool? ?? true;
    
    // If premium but no plan set, default to weekly
    if (_subscriptionStatus == 'premium' && _subscriptionPlan == null) {
      _subscriptionPlan = 'weekly';
    }
    
    final expiry = widget.user['subscriptionExpiry'] as Timestamp?;
    _expiryDate = expiry?.toDate();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: const Color(0xFF1E1E1E),
      title: Text(
        'Edit User: ${widget.user['displayName']}',
        style: const TextStyle(color: Colors.white),
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            DropdownButtonFormField<String>(
              value: _role,
              dropdownColor: const Color(0xFF2E2E2E),
              style: const TextStyle(color: Colors.white),
              decoration: const InputDecoration(
                labelText: 'Role',
                labelStyle: TextStyle(color: Colors.grey),
              ),
              items: ['user', 'admin'].map((role) {
                return DropdownMenuItem(value: role, child: Text(role.toUpperCase()));
              }).toList(),
              onChanged: (value) => setState(() => _role = value!),
            ),
            const SizedBox(height: 16),
            DropdownButtonFormField<String>(
              value: _subscriptionStatus,
              dropdownColor: const Color(0xFF2E2E2E),
              style: const TextStyle(color: Colors.white),
              decoration: const InputDecoration(
                labelText: 'Subscription Status',
                labelStyle: TextStyle(color: Colors.grey),
              ),
              items: ['free', 'premium'].map((status) {
                return DropdownMenuItem(value: status, child: Text(status.toUpperCase()));
              }).toList(),
              onChanged: (value) {
                setState(() {
                  _subscriptionStatus = value!;
                  if (value == 'free') {
                    _subscriptionPlan = null;
                    _expiryDate = null;
                  }
                });
              },
            ),
            if (_subscriptionStatus == 'premium') ...[
              const SizedBox(height: 16),
              DropdownButtonFormField<String>(
                value: _subscriptionPlan,
                dropdownColor: const Color(0xFF2E2E2E),
                style: const TextStyle(color: Colors.white),
                decoration: const InputDecoration(
                  labelText: 'Subscription Plan',
                  labelStyle: TextStyle(color: Colors.grey),
                ),
                items: ['weekly', 'monthly', 'yearly'].map((plan) {
                  return DropdownMenuItem(value: plan, child: Text(plan.toUpperCase()));
                }).toList(),
                onChanged: (value) => setState(() => _subscriptionPlan = value),
              ),
              const SizedBox(height: 16),
              ListTile(
                title: Text(
                  _expiryDate == null
                      ? 'Set Expiry Date'
                      : 'Expiry: ${DateFormat('MMM dd, yyyy').format(_expiryDate!)}',
                  style: const TextStyle(color: Colors.white),
                ),
                trailing: const Icon(Icons.calendar_today, color: Colors.cyanAccent),
                onTap: () async {
                  final date = await showDatePicker(
                    context: context,
                    initialDate: _expiryDate ?? DateTime.now().add(const Duration(days: 30)),
                    firstDate: DateTime.now(),
                    lastDate: DateTime.now().add(const Duration(days: 365 * 2)),
                  );
                  if (date != null) setState(() => _expiryDate = date);
                },
              ),
            ],
            const SizedBox(height: 16),
            SwitchListTile(
              title: const Text('Account Active', style: TextStyle(color: Colors.white)),
              value: _isActive,
              activeColor: Colors.green,
              onChanged: (value) => setState(() => _isActive = value),
            ),
            const SizedBox(height: 16),
            ElevatedButton.icon(
              onPressed: () async {
                try {
                  await _adminService.resetDeviceBinding(widget.user['id']);
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Device binding reset successfully!'), backgroundColor: Colors.green),
                    );
                  }
                } catch (e) {
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red),
                    );
                  }
                }
              },
              icon: const Icon(Icons.phonelink_erase),
              label: const Text('Reset Linked Device'),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.amber[800],
                foregroundColor: Colors.white,
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        ElevatedButton(
          onPressed: _saveChanges,
          style: ElevatedButton.styleFrom(backgroundColor: Colors.green),
          child: const Text('Save'),
        ),
      ],
    );
  }

  Future<void> _saveChanges() async {
    try {
      await _adminService.updateUserRole(widget.user['id'], _role);
      await _adminService.updateSubscriptionStatus(
        userId: widget.user['id'],
        status: _subscriptionStatus,
        plan: _subscriptionPlan,
        expiry: _expiryDate,
      );
      await _adminService.toggleUserStatus(widget.user['id'], _isActive);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('User updated successfully'), backgroundColor: Colors.green),
        );
        widget.onSave();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }
}
