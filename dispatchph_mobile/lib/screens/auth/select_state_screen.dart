import 'package:flutter/material.dart';
import '../../theme/app_theme.dart';
import '../../widgets/primary_button.dart';
import '../../core/services/error_text.dart';
import '../../core/constants/nigerian_states.dart';
import '../../core/services/supabase_service.dart';
import 'home_router.dart';

/// Shown once for accounts created before the state field existed. Once
/// saved here, the state is locked — any further change must go through
/// the "Request State Change" flow and admin approval, not this screen.
class SelectStateScreen extends StatefulWidget {
  final String userId;
  final String role;

  const SelectStateScreen({super.key, required this.userId, required this.role});

  @override
  State<SelectStateScreen> createState() => _SelectStateScreenState();
}

class _SelectStateScreenState extends State<SelectStateScreen> {
  String? _selectedState;
  bool _isSaving = false;

  Future<void> _save() async {
    if (_selectedState == null) return;
    setState(() => _isSaving = true);
    try {
      await SupabaseService.client
          .from('users')
          .update({'state': _selectedState})
          .eq('id', widget.userId);

      if (!mounted) return;
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (_) => HomeRouter(role: widget.role)),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(friendlyError(e, fallback: "We couldn't save your state. Please try again."))),
        );
      }
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.white,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.location_on, color: AppColors.primaryGreen, size: 56),
              const SizedBox(height: 20),
              Text('Select Your State', style: Theme.of(context).textTheme.headlineLarge),
              const SizedBox(height: 8),
              Text(
                widget.role == 'vendor'
                    ? 'We need your state to match you with buyers nearby. '
                        'Once saved, changing it later requires an approved request.'
                    : 'We need your state so you only see vendors who can deliver to you. '
                        'Once saved, changing it later requires an approved request.',
                style: Theme.of(context).textTheme.bodyLarge?.copyWith(color: AppColors.mediumGray),
              ),
              const SizedBox(height: 28),
              DropdownButtonFormField<String>(
                decoration: InputDecoration(
                  labelText: 'Your State',
                  prefixIcon: const Icon(Icons.location_on, color: AppColors.primaryGreen),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                ),
                hint: const Text('Select your state'),
                value: _selectedState,
                items: nigerianStates.map((s) => DropdownMenuItem(value: s, child: Text(s))).toList(),
                onChanged: (v) => setState(() => _selectedState = v),
              ),
              const SizedBox(height: 28),
              PrimaryButton(
                text: 'Save & Continue',
                isLoading: _isSaving,
                onPressed: _selectedState == null ? null : _save,
                backgroundColor: AppColors.primaryGreen,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
