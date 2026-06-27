import 'package:flutter/material.dart';
import '../theme/app_theme.dart';
import '../core/constants/nigerian_states.dart';
import '../core/services/supabase_service.dart';

/// Opens the "Request State Change" flow: pick the desired state, give a
/// reason, and submit. State is locked once set — this just files a
/// request for an admin to approve, it does not change anything itself.
Future<void> showStateChangeRequestDialog(
  BuildContext context, {
  required String userId,
  required String? currentState,
}) async {
  String? requestedState;
  final reasonController = TextEditingController();
  bool isSubmitting = false;

  await showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
    builder: (sheetContext) => StatefulBuilder(
      builder: (context, setSheetState) => Padding(
        padding: EdgeInsets.only(
          left: 20,
          right: 20,
          top: 20,
          bottom: MediaQuery.of(context).viewInsets.bottom + 20,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Request State Change', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            Text(
              'Your state is locked at $currentState to keep delivery reliable. '
              'An admin will review your request before it changes.',
              style: TextStyle(color: Colors.grey[600], fontSize: 12),
            ),
            const SizedBox(height: 16),
            DropdownButtonFormField<String>(
              decoration: InputDecoration(
                labelText: 'New state',
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
              ),
              value: requestedState,
              items: nigerianStates
                  .where((s) => s != currentState)
                  .map((s) => DropdownMenuItem(value: s, child: Text(s)))
                  .toList(),
              onChanged: (v) => setSheetState(() => requestedState = v),
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: reasonController,
              maxLines: 3,
              decoration: InputDecoration(
                labelText: 'Reason for change',
                hintText: 'e.g. I relocated to a new state',
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
              ),
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: (requestedState == null || reasonController.text.trim().isEmpty || isSubmitting)
                    ? null
                    : () async {
                        setSheetState(() => isSubmitting = true);
                        try {
                          await SupabaseService.client.from('state_change_requests').insert({
                            'user_id': userId,
                            'current_state': currentState,
                            'requested_state': requestedState,
                            'reason': reasonController.text.trim(),
                          });
                          if (sheetContext.mounted) Navigator.pop(sheetContext);
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: Text('Request submitted — pending admin review')),
                            );
                          }
                        } catch (e) {
                          setSheetState(() => isSubmitting = false);
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(content: Text('Failed to submit: $e')),
                            );
                          }
                        }
                      },
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.primaryGreen,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
                child: isSubmitting
                    ? const SizedBox(
                        width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                    : const Text('Submit Request', style: TextStyle(color: Colors.white)),
              ),
            ),
          ],
        ),
      ),
    ),
  );

  reasonController.dispose();
}
