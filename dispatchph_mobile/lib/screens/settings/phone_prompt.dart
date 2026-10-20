import 'package:flutter/material.dart';
import '../../theme/app_theme.dart';
import '../../widgets/phone_input.dart';
import '../../core/services/auth_service.dart';

/// If the signed-in user has no valid contact phone, show a one-time prompt to
/// add it (couriers call it for pickup/delivery). New users set it at signup;
/// this backfills existing accounts on app entry. Dismissable with "Later" — it
/// re-prompts on the next launch until a valid number is saved.
Future<void> maybePromptForPhone(BuildContext context) async {
  final profile = await AuthService.loadProfile();
  final phone = profile['phone'] ?? '';
  if (PhoneInputField.isValid(phone)) return; // already has a good number
  final name = profile['name'] ?? '';
  if (!context.mounted) return;

  final controller = TextEditingController();
  await showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (dialogCtx) {
      String? error;
      bool saving = false;
      return StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          icon: const Icon(Icons.phone_android, color: AppColors.primaryGreen, size: 40),
          title: const Text('Add your phone number'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'Couriers call this number for pickup and delivery. Please add it so your orders can be delivered.',
                style: TextStyle(fontSize: 13),
              ),
              const SizedBox(height: 16),
              PhoneInputField(controller: controller, errorText: error),
            ],
          ),
          actions: [
            TextButton(
              onPressed: saving ? null : () => Navigator.pop(ctx),
              child: const Text('Later'),
            ),
            ElevatedButton(
              onPressed: saving
                  ? null
                  : () async {
                      if (!PhoneInputField.isValid(controller.text)) {
                        setLocal(() => error = 'Enter a valid 11-digit number (e.g. 08012345678)');
                        return;
                      }
                      setLocal(() {
                        saving = true;
                        error = null;
                      });
                      final err = await AuthService.updateProfile(
                        name: name,
                        phone: controller.text.trim(),
                      );
                      if (err != null) {
                        setLocal(() {
                          saving = false;
                          error = err;
                        });
                        return;
                      }
                      if (ctx.mounted) Navigator.pop(ctx);
                    },
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.primaryGreen,
                foregroundColor: Colors.white,
              ),
              child: saving
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                    )
                  : const Text('Save'),
            ),
          ],
        ),
      );
    },
  );
  controller.dispose();
}
