import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../../theme/app_theme.dart';
import '../../core/services/supabase_service.dart';
import '../../core/services/auth_service.dart';
import '../auth/welcome_screen.dart';
import 'admin_disputes_screen.dart';
import 'admin_order_reviews_screen.dart';

class AdminStateRequestsScreen extends StatefulWidget {
  const AdminStateRequestsScreen({super.key});

  @override
  State<AdminStateRequestsScreen> createState() => _AdminStateRequestsScreenState();
}

class _AdminStateRequestsScreenState extends State<AdminStateRequestsScreen> {
  List<Map<String, dynamic>> _requests = [];
  Map<String, String> _userNames = {};
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _isLoading = true);
    try {
      final data = await SupabaseService.client
          .from('state_change_requests')
          .select('id, user_id, current_state, requested_state, reason, status, created_at')
          .eq('status', 'pending')
          .order('created_at', ascending: true);

      final requests = List<Map<String, dynamic>>.from(data);
      final userIds = requests.map((r) => r['user_id'] as String).toSet().toList();
      final names = <String, String>{};
      if (userIds.isNotEmpty) {
        final userData = await SupabaseService.client.from('users').select('id, name, email, role').inFilter('id', userIds);
        for (final u in (userData as List)) {
          names[u['id']] = '${u['name']} (${u['role']}) — ${u['email']}';
        }
      }

      if (mounted) {
        setState(() {
          _requests = requests;
          _userNames = names;
          _isLoading = false;
        });
      }
    } catch (e) {
      print('[AdminStateRequests] load error: $e');
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _approve(Map<String, dynamic> request) async {
    final adminId = SupabaseService.auth.currentUser?.id;
    try {
      await SupabaseService.client.from('users').update({
        'state': request['requested_state'],
      }).eq('id', request['user_id']);

      await SupabaseService.client.from('state_change_requests').update({
        'status': 'approved',
        'reviewed_by': adminId,
        'reviewed_at': DateTime.now().toIso8601String(),
      }).eq('id', request['id']);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Approved')));
      }
      _load();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed: $e')));
      }
    }
  }

  Future<void> _reject(Map<String, dynamic> request) async {
    final adminId = SupabaseService.auth.currentUser?.id;
    try {
      await SupabaseService.client.from('state_change_requests').update({
        'status': 'rejected',
        'reviewed_by': adminId,
        'reviewed_at': DateTime.now().toIso8601String(),
      }).eq('id', request['id']);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Rejected')));
      }
      _load();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed: $e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final format = DateFormat('d MMM, h:mm a');
    return Scaffold(
      appBar: AppBar(
        title: const Text('State Change Requests'),
        actions: [
          IconButton(
            icon: const Icon(Icons.gavel),
            tooltip: 'Disputes',
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const AdminDisputesScreen()),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.pending_actions),
            tooltip: 'Orders Needing Review',
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const AdminOrderReviewsScreen()),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.logout),
            onPressed: () async {
              await AuthService.logout();
              if (!context.mounted) return;
              Navigator.pushAndRemoveUntil(
                context,
                MaterialPageRoute(builder: (_) => const WelcomeScreen()),
                (route) => false,
              );
            },
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: _requests.isEmpty
                  ? ListView(
                      children: const [
                        SizedBox(height: 200),
                        Center(child: Text('No pending requests', style: TextStyle(color: AppColors.mediumGray))),
                      ],
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.all(16),
                      itemCount: _requests.length,
                      itemBuilder: (_, i) {
                        final r = _requests[i];
                        final userLabel = _userNames[r['user_id']] ?? r['user_id'];
                        return Card(
                          margin: const EdgeInsets.only(bottom: 12),
                          child: Padding(
                            padding: const EdgeInsets.all(14),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(userLabel, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                                const SizedBox(height: 6),
                                Text(
                                  '${r['current_state'] ?? 'Not set'} → ${r['requested_state']}',
                                  style: const TextStyle(fontWeight: FontWeight.w600, color: AppColors.primaryGreen),
                                ),
                                const SizedBox(height: 6),
                                Text('Reason: ${r['reason']}', style: const TextStyle(fontSize: 13)),
                                const SizedBox(height: 4),
                                Text(
                                  format.format(DateTime.parse(r['created_at'])),
                                  style: const TextStyle(fontSize: 11, color: AppColors.mediumGray),
                                ),
                                const SizedBox(height: 12),
                                Row(
                                  children: [
                                    Expanded(
                                      child: OutlinedButton(
                                        onPressed: () => _reject(r),
                                        style: OutlinedButton.styleFrom(side: const BorderSide(color: Colors.red)),
                                        child: const Text('Reject', style: TextStyle(color: Colors.red)),
                                      ),
                                    ),
                                    const SizedBox(width: 10),
                                    Expanded(
                                      child: ElevatedButton(
                                        onPressed: () => _approve(r),
                                        style: ElevatedButton.styleFrom(backgroundColor: AppColors.primaryGreen),
                                        child: const Text('Approve', style: TextStyle(color: Colors.white)),
                                      ),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
            ),
    );
  }
}
