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
  String _idType = 'nin'; // 'nin' or 'bvn' — the user chooses which to verify with

  @override
  void initState() {
    super.initState();
    // If already verified, bail straight out as success — never show the form or
    // call the provider again (each provider check costs money).
    WidgetsBinding.instance.addPostFrameCallback((_) => _bailIfVerified());
  }

  Future<void> _bailIfVerified() async {
    if (!await KycService.isVerified()) return;
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('You are already verified ✓'), backgroundColor: AppColors.primaryGreen),
    );
    Navigator.pop(context, true);
  }

  @override
  void dispose() {
    _nin.dispose();
    _first.dispose();
    _last.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final id = _nin.text.trim();
    final first = _first.text.trim();
    final last = _last.text.trim();
    final label = _idType.toUpperCase();
    if (!RegExp(r'^\d{11}$').hasMatch(id)) {
      setState(() => _error = 'Enter your 11-digit $label');
      return;
    }
    // Both names are required — we match them against the name registered to the
    // ID, so a blank field (or just an account nickname) can't verify.
    if (first.isEmpty || last.isEmpty) {
      setState(() => _error = 'Enter your first name and surname exactly as on your $label');
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    final res = await KycService.submitNin(
      nin: id,
      idType: _idType,
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
              'Verify your identity with your National Identification Number (NIN) '
              'or Bank Verification Number (BVN) — whichever you prefer. It only '
              'takes a moment, and your ID is never shared with vendors.',
              style: TextStyle(color: AppColors.mediumGray, height: 1.5),
            ),
            const SizedBox(height: 20),
            SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'nin', label: Text('NIN'), icon: Icon(Icons.badge_outlined)),
                ButtonSegment(value: 'bvn', label: Text('BVN'), icon: Icon(Icons.account_balance_outlined)),
              ],
              selected: {_idType},
              onSelectionChanged: (s) => setState(() {
                _idType = s.first;
                _error = null;
              }),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _nin,
              keyboardType: TextInputType.number,
              maxLength: 11,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              decoration: InputDecoration(
                labelText: '${_idType.toUpperCase()} (11 digits)',
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
              '🔒 Your NIN/BVN is sent securely to our verification provider and '
              'is not shared with vendors.',
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
enum KycAction { buy, sell, withdraw, fund }

String _kycPrompt(KycAction action) {
  switch (action) {
    case KycAction.sell:
      return 'You need to verify your identity with your NIN before you '
          'can list products for sale. It only takes a moment.';
    case KycAction.withdraw:
      return 'You need to verify your identity with your NIN before you '
          'can withdraw to your bank. It only takes a moment.';
    case KycAction.fund:
      return 'You need to verify your identity with your NIN before you '
          'can create your funding account. It only takes a moment.';
    case KycAction.buy:
      return 'You need to verify your identity with your NIN before you '
          'can buy. It only takes a moment.';
  }
}

/// Gate used before a protected action. Returns true if the user is verified.
/// If not, shows a prompt; if they choose to verify and succeed, returns true.
Future<bool> requireKyc(BuildContext context, {KycAction action = KycAction.buy}) async {
  // Buyers are no longer identity-gated to BUY — anyone can purchase (paying by
  // card / transfer / wallet). Verification now only protects SELLING and bank
  // WITHDRAWALS. (Funding a wallet via the legacy virtual account still needs
  // NIN server-side until funding moves onto the new checkout.)
  if (action == KycAction.buy) return true;
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

/// (Retired) Buyers no longer need to verify to buy, so the old home-screen
/// "verify your identity" nudge is a no-op. Kept as a stub so existing call
/// sites keep compiling.
Future<void> promptKycReminder(BuildContext context) async {}
