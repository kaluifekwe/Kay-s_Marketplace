import 'package:flutter/material.dart';
import '../../theme/app_theme.dart';
import '../../widgets/primary_button.dart';
import '../../core/services/error_text.dart';
import '../../core/services/policy_service.dart';
import '../policy/policy_screen.dart';

/// Mandatory gate: the buyer/vendor must read and accept the current agreement
/// before reaching the app. Cannot be dismissed (no back button). On accept it
/// records the acceptance and replaces itself with [home].
class PolicyGateScreen extends StatefulWidget {
  final String role;
  final String userId;
  final Widget home;

  const PolicyGateScreen({
    super.key,
    required this.role,
    required this.userId,
    required this.home,
  });

  @override
  State<PolicyGateScreen> createState() => _PolicyGateScreenState();
}

class _PolicyGateScreenState extends State<PolicyGateScreen> {
  bool _agreed = false;
  bool _isSaving = false;

  Future<void> _accept() async {
    if (!_agreed || _isSaving) return;
    setState(() => _isSaving = true);
    try {
      await PolicyService.acceptCurrent(userId: widget.userId, role: widget.role);
      if (!mounted) return;
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (_) => widget.home),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _isSaving = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(friendlyError(e, fallback: "We couldn't save your acceptance. Please try again."))),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    // Block back-navigation: accepting is the only way forward.
    return PopScope(
      canPop: false,
      child: Scaffold(
        backgroundColor: AppColors.white,
        appBar: AppBar(
          title: const Text('Before you continue'),
          automaticallyImplyLeading: false,
        ),
        body: SafeArea(
          child: Column(
            children: [
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(24),
                  child: const PolicyBody(),
                ),
              ),
              Container(
                padding: const EdgeInsets.fromLTRB(24, 12, 24, 16),
                decoration: BoxDecoration(
                  color: AppColors.white,
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withAlpha(20),
                      blurRadius: 12,
                      offset: const Offset(0, -2),
                    ),
                  ],
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    CheckboxListTile(
                      value: _agreed,
                      onChanged: _isSaving
                          ? null
                          : (v) => setState(() => _agreed = v ?? false),
                      controlAffinity: ListTileControlAffinity.leading,
                      contentPadding: EdgeInsets.zero,
                      activeColor: AppColors.primaryGreen,
                      title: const Text(
                        'I have read and agree to the Buyer & Vendor Agreement',
                        style: TextStyle(fontSize: 14),
                      ),
                    ),
                    const SizedBox(height: 4),
                    SizedBox(
                      width: double.infinity,
                      child: PrimaryButton(
                        text: 'I Agree',
                        isLoading: _isSaving,
                        onPressed: _agreed ? _accept : null,
                        backgroundColor: AppColors.primaryGreen,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
