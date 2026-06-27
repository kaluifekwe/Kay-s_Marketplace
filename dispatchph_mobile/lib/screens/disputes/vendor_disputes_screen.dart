import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:intl/intl.dart';
import '../../theme/app_theme.dart';
import '../../bloc_exports.dart';
import '../../core/models/models.dart';
import '../../core/services/supabase_service.dart';
import '../orders/vendor_dispute_screen.dart';

class VendorDisputesScreen extends StatefulWidget {
  const VendorDisputesScreen({super.key});

  @override
  State<VendorDisputesScreen> createState() => _VendorDisputesScreenState();
}

class _VendorDisputesScreenState extends State<VendorDisputesScreen> {
  Timer? _refreshTimer;
  String _selectedFilter = 'All';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadDisputes());
    _refreshTimer = Timer.periodic(const Duration(seconds: 5), (_) => _loadDisputes());
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    super.dispose();
  }

  Future<void> _loadDisputes() async {
    final userId = SupabaseService.auth.currentUser?.id ?? '';
    if (userId.isNotEmpty && mounted) {
      context.read<DisputeCubit>().loadDisputesForVendor(userId);
    }
  }

  List<Dispute> _filterDisputes(List<Dispute> disputes) {
    if (_selectedFilter == 'All') return disputes;
    final now = DateTime.now();
    return disputes.where((d) {
      final dt = d.createdAt;
      switch (_selectedFilter) {
        case 'Today':
          return dt.year == now.year && dt.month == now.month && dt.day == now.day;
        case 'This Week':
          final weekAgo = now.subtract(const Duration(days: 7));
          return dt.isAfter(weekAgo);
        case 'This Month':
          return dt.year == now.year && dt.month == now.month;
        default:
          return true;
      }
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Disputes & Refunds')),
      body: BlocBuilder<DisputeCubit, DisputeState>(
        builder: (context, state) {
          if (state.isLoading) return const Center(child: CircularProgressIndicator());

          final filtered = _filterDisputes(state.vendorDisputes);

          if (state.vendorDisputes.isEmpty) {
            return Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.gavel, size: 64, color: AppColors.mediumGray),
                  const SizedBox(height: 16),
                  const Text('No disputes', style: TextStyle(color: AppColors.mediumGray, fontSize: 16)),
                  const SizedBox(height: 8),
                  const Text('Disputes from buyers will appear here',
                      style: TextStyle(color: AppColors.mediumGray, fontSize: 12)),
                ],
              ),
            );
          }

          return Column(
            children: [
              _buildFilterBar(state.vendorDisputes.length),
              if (filtered.isEmpty)
                Expanded(
                  child: Center(
                    child: Text(
                      'No disputes for "$_selectedFilter"',
                      style: const TextStyle(color: AppColors.mediumGray, fontSize: 14),
                    ),
                  ),
                )
              else
                Expanded(
                  child: RefreshIndicator(
                    onRefresh: _loadDisputes,
                    child: ListView.separated(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                      itemCount: filtered.length,
                      separatorBuilder: (_, __) => const SizedBox(height: 8),
                      itemBuilder: (_, i) {
                        final dispute = filtered[i];
                        return _DisputeTile(dispute: dispute);
                      },
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildFilterBar(int totalCount) {
    final filters = ['All', 'Today', 'This Week', 'This Month'];
    return Container(
      height: 56,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        children: [
          Text('$totalCount disputes',
              style: const TextStyle(fontSize: 12, color: AppColors.mediumGray)),
          const SizedBox(width: 12),
          Expanded(
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: filters.length,
              separatorBuilder: (_, __) => const SizedBox(width: 8),
              itemBuilder: (_, i) {
                final f = filters[i];
                final selected = f == _selectedFilter;
                return ChoiceChip(
                  label: Text(f, style: TextStyle(
                    fontSize: 12,
                    color: selected ? Colors.white : AppColors.charcoal,
                    fontWeight: selected ? FontWeight.bold : FontWeight.normal,
                  )),
                  selected: selected,
                  selectedColor: AppColors.primaryGreen,
                  backgroundColor: Colors.grey[100],
                  onSelected: (_) => setState(() => _selectedFilter = f),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _DisputeTile extends StatelessWidget {
  final Dispute dispute;
  const _DisputeTile({required this.dispute});

  String _formatDate(DateTime dt) {
    final now = DateTime.now();
    final diff = now.difference(dt);
    if (diff.inMinutes < 1) return 'Just now';
    if (diff.inHours < 1) return '${diff.inMinutes}m ago';
    if (diff.inDays < 1) return DateFormat('h:mm a').format(dt);
    if (diff.inDays < 7) return DateFormat('EEE, h:mm a').format(dt);
    return DateFormat('MMM d, h:mm a').format(dt);
  }

  @override
  Widget build(BuildContext context) {
    Color statusColor;
    String statusText;
    switch (dispute.status) {
      case 'open':
        statusColor = AppColors.errorRed;
        statusText = 'Needs Attention';
        break;
      case 'vendor_responded':
        statusColor = AppColors.escrowBlue;
        statusText = 'Responded';
        break;
      case 'replacement_offered':
        statusColor = AppColors.escrowBlue;
        statusText = 'Awaiting Buyer';
        break;
      case 'replacement_accepted':
      case 'resolved':
        statusColor = AppColors.successGreen;
        statusText = 'Resolved';
        break;
      case 'rejected':
        statusColor = AppColors.mediumGray;
        statusText = 'Rejected';
        break;
      default:
        statusColor = AppColors.mediumGray;
        statusText = dispute.status;
    }

    final dateStr = _formatDate(dispute.createdAt);

    return Card(
      margin: EdgeInsets.zero,
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        leading: CircleAvatar(
          backgroundColor: statusColor.withAlpha(30),
          child: Icon(Icons.gavel, color: statusColor, size: 20),
        ),
        title: Text(
          'Order #${dispute.orderId.substring(0, 8)}',
          style: TextStyle(
            fontWeight: dispute.status == 'open' ? FontWeight.bold : FontWeight.w600,
          ),
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 2),
            Text(
              dispute.reason,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 13),
            ),
            const SizedBox(height: 4),
            Row(
              children: [
                Icon(Icons.access_time, color: AppColors.mediumGray, size: 12),
                const SizedBox(width: 4),
                Text(dateStr, style: const TextStyle(color: AppColors.mediumGray, fontSize: 11)),
              ],
            ),
          ],
        ),
        trailing: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: statusColor.withAlpha(20),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Text(statusText, style: TextStyle(color: statusColor, fontSize: 11, fontWeight: FontWeight.bold)),
        ),
        onTap: () => Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => BlocProvider.value(
              value: context.read<DisputeCubit>(),
              child: VendorDisputeScreen(disputeId: dispute.id),
            ),
          ),
        ).then((_) {
          final userId = SupabaseService.auth.currentUser?.id ?? '';
          context.read<DisputeCubit>().loadDisputesForVendor(userId);
        }),
      ),
    );
  }
}
