import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../../core/services/error_text.dart';
import '../../theme/app_theme.dart';
import '../../core/services/credit_service.dart';
import '../../core/services/payment_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

// Same bank-logo source used by the vendor bank account screen
// (lib/screens/vendor/bank_account_screen.dart) — kept duplicated here
// rather than extracted into a shared module, to keep this a contained fix.
const Map<String, String> _kGuaranteedBankLogos = {
  '044': 'https://nigerianbanks.xyz/logo/access-bank.png',
  '014': 'https://nigerianbanks.xyz/logo/access-bank.png',
  '057': 'https://nigerianbanks.xyz/logo/guaranty-trust-bank.png',
  '101': 'https://nigerianbanks.xyz/logo/zenith-bank.png',
  '033': 'https://nigerianbanks.xyz/logo/united-bank-for-africa.png',
  '011': 'https://nigerianbanks.xyz/logo/first-bank-of-nigeria.png',
  '070': 'https://nigerianbanks.xyz/logo/fidelity-bank.png',
  '023': 'https://nigerianbanks.xyz/logo/sterling-bank.png',
  '035': 'https://nigerianbanks.xyz/logo/wema-bank.png',
  '082': 'https://nigerianbanks.xyz/logo/keystone-bank.png',
  '214': 'https://nigerianbanks.xyz/logo/first-city-monument-bank.png',
  '076': 'https://nigerianbanks.xyz/logo/polaris-bank.png',
  '032': 'https://nigerianbanks.xyz/logo/union-bank.png',
  '050': 'https://nigerianbanks.xyz/logo/ecobank.png',
  '030': 'https://nigerianbanks.xyz/logo/heritage-bank.png',
  '215': 'https://nigerianbanks.xyz/logo/unity-bank.png',
  '232': 'https://nigerianbanks.xyz/logo/sterling-bank.png',
  '068': 'https://nigerianbanks.xyz/logo/zenith-bank.png',
  '301': 'https://nigerianbanks.xyz/logo/jaiz-bank.png',
  '302': 'https://nigerianbanks.xyz/logo/taj-bank.png',
  '102': 'https://nigerianbanks.xyz/logo/titan-trust-bank.png',
  '090': 'https://nigerianbanks.xyz/logo/providus-bank.png',
  '100': 'https://nigerianbanks.xyz/logo/suntrust-bank.png',
  '037': 'https://nigerianbanks.xyz/logo/alternative-bank.png',
};

const List<String> _kPopularBankCodes = [
  '057', '044', '101', '033', '011', '070', '023', '035', '082', '076',
];

String _bankLogoUrl(String code, String name) {
  if (_kGuaranteedBankLogos.containsKey(code)) {
    return _kGuaranteedBankLogos[code]!;
  }
  final slug = name
      .toLowerCase()
      .replaceAll(RegExp(r'\(.*?\)'), '')
      .replaceAll(' ', '-')
      .replaceAll(RegExp(r'[^a-z0-9-]'), '')
      .replaceAll(RegExp(r'-+'), '-')
      .replaceAll(RegExp(r'^-|-$'), '');
  return 'https://nigerianbanks.xyz/logo/$slug.png';
}

Widget _buildBankLogo(String code, String name, {double size = 40}) {
  final logoUrl = _bankLogoUrl(code, name);
  final initial = name.isNotEmpty ? name[0].toUpperCase() : '?';

  return Container(
    width: size,
    height: size,
    decoration: BoxDecoration(
      color: AppColors.primaryGreen.withAlpha(15),
      borderRadius: BorderRadius.circular(8),
      border: Border.all(color: AppColors.primaryGreen.withAlpha(30)),
    ),
    clipBehavior: Clip.antiAlias,
    child: CachedNetworkImage(
      imageUrl: logoUrl,
      fit: BoxFit.contain,
      memCacheWidth: (size * 2).toInt(),
      placeholder: (_, __) => Center(
        child: Text(
          initial,
          style: TextStyle(color: AppColors.primaryGreen, fontWeight: FontWeight.bold, fontSize: size * 0.4),
        ),
      ),
      errorWidget: (_, __, ___) => Center(
        child: Text(
          initial,
          style: TextStyle(color: AppColors.primaryGreen, fontWeight: FontWeight.bold, fontSize: size * 0.4),
        ),
      ),
    ),
  );
}

class BuyerBankAccountScreen extends StatefulWidget {
  const BuyerBankAccountScreen({super.key});

  @override
  State<BuyerBankAccountScreen> createState() => _BuyerBankAccountScreenState();
}

class _BuyerBankAccountScreenState extends State<BuyerBankAccountScreen> {
  List<Map<String, dynamic>> _banks = [];
  Map<String, dynamic>? _selectedBank;
  final _accountController = TextEditingController();
  String _verifiedName = '';
  bool _isVerifying = false;
  bool _isSaving = false;
  bool _hasExistingAccount = false;
  Map<String, dynamic>? _existingBank;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  Future<void> _loadData() async {
    try {
      final banks = await PaymentService.listBanks();
      if (mounted) setState(() => _banks = banks);

      final prefs = await SharedPreferences.getInstance();
      final buyerId = prefs.getString('auth_user_id') ?? '';
      if (buyerId.isNotEmpty) {
        final bank = await CreditService.getBankAccount(buyerId);
        if (bank != null && mounted) {
          setState(() {
            _hasExistingAccount = true;
            _existingBank = bank;
            _loading = false;
          });
          return;
        }
      }
    } catch (e) {
      print('[BuyerBankAccount] load error: $e');
    }
    if (mounted) setState(() => _loading = false);
  }

  void _openBankSelector() {
    if (_banks.isEmpty) return;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => _BuyerBankSelectionSheet(
        banks: _banks,
        selectedCode: _selectedBank?['code'],
        onSelect: (bank) {
          setState(() {
            _selectedBank = bank;
            _verifiedName = '';
          });
          Navigator.pop(ctx);
        },
      ),
    );
  }

  Future<void> _verifyAccount() async {
    if (_selectedBank == null || _accountController.text.length != 10) return;
    setState(() => _isVerifying = true);

    try {
      final prefs = await SharedPreferences.getInstance();
      final buyerId = prefs.getString('auth_user_id') ?? '';

      final result = await CreditService.verifyBankAccount(
        buyerId: buyerId,
        accountNumber: _accountController.text,
        bankCode: _selectedBank!['code'] as String,
      );

      if (mounted) {
        setState(() {
          _verifiedName = result['account_name'] as String? ?? '';
          _isVerifying = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isVerifying = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(friendlyError(e, fallback: "We couldn't confirm that account. Check the number and bank.")), backgroundColor: AppColors.errorRed),
        );
      }
    }
  }

  Future<void> _saveAccount() async {
    if (_verifiedName.isEmpty || _selectedBank == null) return;
    setState(() => _isSaving = true);

    try {
      final prefs = await SharedPreferences.getInstance();
      final buyerId = prefs.getString('auth_user_id') ?? '';

      await CreditService.saveBankAccount(
        buyerId: buyerId,
        bankName: _selectedBank!['name'] as String,
        bankCode: _selectedBank!['code'] as String,
        accountNumber: _accountController.text,
        accountName: _verifiedName,
      );

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Bank account saved!'), backgroundColor: AppColors.successGreen),
        );
        Navigator.pop(context);
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isSaving = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(friendlyError(e, fallback: "We couldn't save your bank account. Please try again.")), backgroundColor: AppColors.errorRed),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Refund Bank Account')),
      body: _loading
          ? const Center(child: CircularProgressIndicator(color: AppColors.primaryGreen))
          : _hasExistingAccount
              ? _buildExistingAccount()
              : _buildAddForm(),
    );
  }

  Widget _buildExistingAccount() {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      _buildBankLogo(
                        (_existingBank!['bank_code'] ?? '') as String,
                        (_existingBank!['bank_name'] ?? '') as String,
                        size: 32,
                      ),
                      const SizedBox(width: 12),
                      const Text('Saved Bank Account',
                          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                    ],
                  ),
                  const Divider(height: 24),
                  Text('Bank: ${_existingBank!['bank_name']}',
                      style: const TextStyle(fontSize: 15)),
                  const SizedBox(height: 4),
                  Text(
                    'Account: •••• ${(_existingBank!['account_number'] as String).substring((_existingBank!['account_number'] as String).length - 4)}',
                    style: const TextStyle(fontSize: 15),
                  ),
                  const SizedBox(height: 4),
                  Text('Name: ${_existingBank!['account_name']}',
                      style: const TextStyle(fontSize: 15)),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      Icon(
                        (_existingBank!['is_verified'] as bool?) == true
                            ? Icons.verified
                            : Icons.warning,
                        size: 16,
                        color: (_existingBank!['is_verified'] as bool?) == true
                            ? AppColors.successGreen
                            : AppColors.warningOrange,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        (_existingBank!['is_verified'] as bool?) == true ? 'Verified' : 'Pending verification',
                        style: TextStyle(
                          fontSize: 13,
                          color: (_existingBank!['is_verified'] as bool?) == true
                              ? AppColors.successGreen
                              : AppColors.warningOrange,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          const Text(
            'This account will be used for bank transfer refunds.',
            style: TextStyle(color: AppColors.mediumGray, fontSize: 13),
          ),
        ],
      ),
    );
  }

  Widget _buildAddForm() {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const Card(
          child: Padding(
            padding: EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.info_outline, color: AppColors.escrowBlue),
                    SizedBox(width: 8),
                    Text('Why add a bank account?',
                        style: TextStyle(fontWeight: FontWeight.bold)),
                  ],
                ),
                SizedBox(height: 8),
                Text(
                  'For fast refunds to your bank if you ever need one. Refunds arrive in ~10 minutes instead of 5-7 days.',
                  style: TextStyle(color: AppColors.mediumGray, fontSize: 13),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        const Text('Select Bank', style: TextStyle(fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        GestureDetector(
          onTap: _openBankSelector,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            decoration: BoxDecoration(
              border: Border.all(color: AppColors.lightGray),
              borderRadius: BorderRadius.circular(8),
            ),
            child: _selectedBank != null
                ? Row(
                    children: [
                      _buildBankLogo(_selectedBank!['code'] ?? '', _selectedBank!['name'] ?? ''),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(_selectedBank!['name'] ?? 'Unknown', style: const TextStyle(fontSize: 14)),
                      ),
                      const Icon(Icons.arrow_drop_down, color: AppColors.mediumGray),
                    ],
                  )
                : Row(
                    children: [
                      if (_banks.isEmpty)
                        const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                      else
                        const Icon(Icons.account_balance, color: AppColors.mediumGray),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          _banks.isEmpty ? 'Loading banks...' : 'Choose your bank',
                          style: const TextStyle(color: AppColors.mediumGray, fontSize: 14),
                        ),
                      ),
                      const Icon(Icons.arrow_drop_down, color: AppColors.mediumGray),
                    ],
                  ),
          ),
        ),
        const SizedBox(height: 16),
        const Text('Account Number', style: TextStyle(fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        TextField(
          controller: _accountController,
          keyboardType: TextInputType.number,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(10)],
          decoration: InputDecoration(
            hintText: 'Enter 10-digit account number',
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
          ),
          onChanged: (_) => setState(() => _verifiedName = ''),
        ),
        if (_verifiedName.isNotEmpty) ...[
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: AppColors.successGreen.withAlpha(15),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              children: [
                const Icon(Icons.check_circle, color: AppColors.successGreen, size: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(_verifiedName,
                      style: const TextStyle(fontWeight: FontWeight.bold, color: AppColors.successGreen)),
                ),
              ],
            ),
          ),
        ],
        const SizedBox(height: 24),
        if (_verifiedName.isEmpty)
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: (_selectedBank != null && _accountController.text.length == 10 && !_isVerifying)
                  ? _verifyAccount
                  : null,
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.escrowBlue,
                padding: const EdgeInsets.symmetric(vertical: 16),
              ),
              child: _isVerifying
                  ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                  : const Text('Verify Account', style: TextStyle(color: Colors.white)),
            ),
          )
        else
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: _isSaving ? null : _saveAccount,
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.primaryGreen,
                padding: const EdgeInsets.symmetric(vertical: 16),
              ),
              child: _isSaving
                  ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                  : const Text('Save Bank Account', style: TextStyle(color: Colors.white)),
            ),
          ),
      ],
    );
  }
}

class _BuyerBankSelectionSheet extends StatefulWidget {
  final List<Map<String, dynamic>> banks;
  final String? selectedCode;
  final void Function(Map<String, dynamic>) onSelect;

  const _BuyerBankSelectionSheet({
    required this.banks,
    required this.selectedCode,
    required this.onSelect,
  });

  @override
  State<_BuyerBankSelectionSheet> createState() => _BuyerBankSelectionSheetState();
}

class _BuyerBankSelectionSheetState extends State<_BuyerBankSelectionSheet> {
  final _searchController = TextEditingController();
  String _query = '';

  List<Map<String, dynamic>> get _filteredBanks {
    if (_query.isEmpty) return widget.banks;
    final q = _query.toLowerCase();
    return widget.banks.where((b) {
      final name = (b['name'] ?? '').toString().toLowerCase();
      final code = (b['code'] ?? '').toString().toLowerCase();
      return name.contains(q) || code.contains(q);
    }).toList();
  }

  List<Map<String, dynamic>> get _popularBanks {
    return widget.banks.where((b) => _kPopularBankCodes.contains(b['code'])).toList();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final filtered = _filteredBanks;
    final popular = _query.isEmpty ? _popularBanks : <Map<String, dynamic>>[];
    final others = _query.isEmpty
        ? filtered.where((b) => !_kPopularBankCodes.contains(b['code'])).toList()
        : filtered;

    return DraggableScrollableSheet(
      initialChildSize: 0.9,
      minChildSize: 0.5,
      maxChildSize: 0.95,
      expand: false,
      builder: (ctx, scrollController) {
        return Column(
          children: [
            Container(
              margin: const EdgeInsets.only(top: 12),
              width: 40,
              height: 4,
              decoration: BoxDecoration(color: Colors.grey[300], borderRadius: BorderRadius.circular(2)),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
              child: Row(
                children: [
                  const Expanded(
                    child: Text('Select Bank', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                  ),
                  IconButton(onPressed: () => Navigator.pop(ctx), icon: const Icon(Icons.close)),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: TextField(
                controller: _searchController,
                autofocus: true,
                decoration: InputDecoration(
                  hintText: 'Search banks...',
                  prefixIcon: const Icon(Icons.search, size: 20),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                  contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  suffixIcon: _query.isNotEmpty
                      ? IconButton(
                          icon: const Icon(Icons.clear, size: 18),
                          onPressed: () {
                            _searchController.clear();
                            setState(() => _query = '');
                          },
                        )
                      : null,
                ),
                onChanged: (val) => setState(() => _query = val),
              ),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: ListView(
                controller: scrollController,
                padding: const EdgeInsets.symmetric(horizontal: 20),
                children: [
                  if (popular.isNotEmpty) ...[
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 8),
                      child: Text('POPULAR BANKS',
                          style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: Colors.grey, letterSpacing: 1)),
                    ),
                    ...popular.map((bank) => _buildBankTile(bank)),
                    const Padding(padding: EdgeInsets.symmetric(vertical: 12), child: Divider()),
                  ],
                  if (_query.isNotEmpty && filtered.isEmpty)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 40),
                      child: Center(child: Text('No banks found', style: TextStyle(color: Colors.grey, fontSize: 15))),
                    )
                  else ...[
                    if (_query.isEmpty)
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 8),
                        child: Text('ALL BANKS',
                            style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: Colors.grey, letterSpacing: 1)),
                      ),
                    ...others.map((bank) => _buildBankTile(bank)),
                  ],
                  const SizedBox(height: 20),
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildBankTile(Map<String, dynamic> bank) {
    final code = bank['code'] ?? '';
    final name = bank['name'] ?? 'Unknown';
    final isSelected = code == widget.selectedCode;

    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: _buildBankLogo(code, name),
      title: Text(name, style: TextStyle(fontSize: 14, fontWeight: isSelected ? FontWeight.w600 : FontWeight.w400)),
      trailing: isSelected ? const Icon(Icons.check_circle, color: AppColors.primaryGreen, size: 20) : null,
      onTap: () => widget.onSelect(bank),
    );
  }
}
