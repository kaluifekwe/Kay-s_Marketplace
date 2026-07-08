import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../theme/app_theme.dart';
import '../../widgets/primary_button.dart';
import '../../core/services/kyc_service.dart';

/// Buyer NIN verification screen. On success pops `true`.
class KycScreen extends StatefulWidget {
  const KycScreen({super.key});

  @override
  State<KycScreen> createState() => _KycScreenState();
}

class _KycScreenState extends State<KycScreen> {
  final _nin = TextEditingController();
  final _first = TextEditingController();
  final _last = TextEditingController();
  bool _loading = false;
  String? _error;

  @override
  void dispose() {
    _nin.dispose();
    _first.dispose();
    _last.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final nin = _nin.text.trim();
    final first = _first.text.trim();
    final last = _last.text.trim();
    if (!RegExp(r'^\d{11}$').hasMatch(nin)) {
      setState(() => _error = 'Enter your 11-digit NIN');
      return;
    }
    // Both names are required — we match them against the name registered to the
    // NIN, so a blank field (or just an account nickname) can't verify.
    if (first.isEmpty || last.isEmpty) {
      setState(() => _error = 'Enter your first name and surname exactly as on your NIN');
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    final res = await KycService.submitNin(
      nin: nin,
      firstName: first,
      lastName: last,
    );
    if (!mounted) return;
    setState(() => _loading = false);
    if (res.ok) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Identity verified ✓'), backgroundColor: AppColors.primaryGreen),
      );
      Navigator.pop(context, true);
    } else {
      setState(() => _error = res.error);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.white,
      appBar: AppBar(title: const Text('Verify your identity')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Icon(Icons.verified_user, color: AppColors.primaryGreen, size: 48),
            const SizedBox(height: 16),
            Text('One-time verification', style: Theme.of(context).textTheme.headlineSmall),
            const SizedBox(height: 8),
            const Text(
              'To keep the marketplace safe, we verify every buyer with their '
              'National Identification Number (NIN) before their first purchase. '
              'You can browse freely — verification is only needed to buy.',
              style: TextStyle(color: AppColors.mediumGray, height: 1.5),
            ),
            const SizedBox(height: 24),
            TextField(
              controller: _nin,
              keyboardType: TextInputType.number,
              maxLength: 11,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              decoration: const InputDecoration(
                labelText: 'NIN (11 digits)',
                hintText: 'e.g., 12345678901',
                counterText: '',
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _first,
                    decoration: const InputDecoration(labelText: 'First name (as on NIN)'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    controller: _last,
                    decoration: const InputDecoration(labelText: 'Surname (as on NIN)'),
                  ),
                ),
              ],
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(_error!, style: const TextStyle(color: AppColors.errorRed)),
            ],
            const SizedBox(height: 24),
            PrimaryButton(
              text: 'Verify',
              isLoading: _loading,
              onPressed: _loading ? null : _submit,
              backgroundColor: AppColors.primaryGreen,
            ),
            const SizedBox(height: 12),
            const Text(
              '🔒 Your NIN is sent securely to our verification provider and is '
              'not shared with vendors.',
              style: TextStyle(fontSize: 12, color: AppColors.mediumGray),
            ),
          ],
        ),
      ),
    );
  }
}

/// What a KYC gate is protecting — tunes the prompt copy. The verification
/// itself is identical (NIN/BVN); only the reason shown to the user differs.
enum KycAction { buy, sell, withdraw }

String _kycPrompt(KycAction action) {
  switch (action) {
    case KycAction.sell:
      return 'You need to verify your identity with your NIN or BVN before you '
          'can list products for sale. It only takes a moment.';
    case KycAction.withdraw:
      return 'You need to verify your identity with your NIN or BVN before you '
          'can withdraw to your bank. It only takes a moment.';
    case KycAction.buy:
      return 'You need to verify your identity with your NIN or BVN before you '
          'can buy. It only takes a moment.';
  }
}

/// Gate used before a protected action. Returns true if the user is verified.
/// If not, shows a prompt; if they choose to verify and succeed, returns true.
Future<bool> requireKyc(BuildContext context, {KycAction action = KycAction.buy}) async {
  if (await KycService.isVerified()) return true;
  if (!context.mounted) return false;
  final title = action == KycAction.buy ? 'Verify to buy' : 'Verify your identity';
  final proceed = await showDialog<bool>(
    context: context,
    builder: (_) => AlertDialog(
      icon: const Icon(Icons.verified_user, color: AppColors.primaryGreen, size: 48),
      title: Text(title),
      content: Text(_kycPrompt(action), textAlign: TextAlign.center),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Not now')),
        ElevatedButton(onPressed: () => Navigator.pop(context, true), child: const Text('Verify now')),
      ],
    ),
  );
  if (proceed != true || !context.mounted) return false;
  final verified = await Navigator.push<bool>(
    context,
    MaterialPageRoute(builder: (_) => const KycScreen()),
  );
  return verified == true;
}

/// Non-blocking nudge shown on the buyer home while unverified.
Future<void> promptKycReminder(BuildContext context) async {
  if (await KycService.isVerified()) return;
  if (!context.mounted) return;
  await showDialog<void>(
    context: context,
    builder: (_) => AlertDialog(
      icon: const Icon(Icons.verified_user_outlined, color: AppColors.primaryGreen, size: 44),
      title: const Text('Verify your identity'),
      content: const Text(
        'Browse all you like — but to buy from vendors you\'ll need to verify '
        'your NIN first. It only takes a moment.',
        textAlign: TextAlign.center,
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Maybe later')),
        ElevatedButton(
          onPressed: () {
            Navigator.pop(context);
            Navigator.push(context, MaterialPageRoute(builder: (_) => const KycScreen()));
          },
          child: const Text('Verify now'),
        ),
      ],
    ),
  );
}
