import 'package:flutter/material.dart';
import '../../theme/app_theme.dart';
import '../../core/services/account_service.dart';
import '../../core/services/auth_service.dart';
import '../auth/welcome_screen.dart';

/// Confirm-and-delete flow for permanent account deletion (Play requirement).
/// Shows a warning + typed confirmation, deletes the account, signs out, and
/// returns the user to the welcome screen. Call from a "Delete account" tile.
Future<void> deleteAccountFlow(BuildContext context) async {
  final confirmController = TextEditingController();
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setState) {
        final canDelete = confirmController.text.trim().toUpperCase() == 'DELETE';
        return AlertDialog(
          icon: const Icon(Icons.warning_amber_rounded, color: AppColors.errorRed, size: 44),
          title: const Text('Delete your account?'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'This permanently deletes your account and all your data — profile, '
                'orders, wallet, and store. This cannot be undone.\n\n'
                'If you have money in your wallet, withdraw it first.\n\n'
                'Type DELETE to confirm.',
                style: TextStyle(fontSize: 13, color: AppColors.mediumGray),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: confirmController,
                autofocus: true,
                textCapitalization: TextCapitalization.characters,
                onChanged: (_) => setState(() {}),
                decoration: const InputDecoration(hintText: 'DELETE', border: OutlineInputBorder()),
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: AppColors.errorRed, foregroundColor: Colors.white),
              onPressed: canDelete ? () => Navigator.pop(ctx, true) : null,
              child: const Text('Delete'),
            ),
          ],
        );
      },
    ),
  );

  if (confirmed != true || !context.mounted) return;

  // Progress spinner while we delete.
  showDialog(
    context: context,
    barrierDismissible: false,
    builder: (_) => const Center(child: CircularProgressIndicator(color: AppColors.primaryGreen)),
  );

  try {
    await AccountService.deleteAccount();
    await AuthService.logout();
    if (!context.mounted) return;
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const WelcomeScreen()),
      (route) => false,
    );
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Your account has been deleted.')),
    );
  } catch (e) {
    if (!context.mounted) return;
    Navigator.pop(context); // close the spinner
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Could not delete'),
        content: Text(e.toString().replaceFirst('Exception: ', '')),
        actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('OK'))],
      ),
    );
  }
}
