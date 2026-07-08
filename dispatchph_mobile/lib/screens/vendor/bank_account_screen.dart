import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../core/services/error_text.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../../theme/app_theme.dart';
import '../../core/services/auth_service.dart';
import '../../core/services/payment_service.dart';

class BankAccountScreen extends StatefulWidget {
  const BankAccountScreen({super.key});

  @override
  State<BankAccountScreen> createState() => _BankAccountScreenState();
}

class _BankAccountScreenState extends State<BankAccountScreen> {
  List<Map<String, dynamic>> _banks = [];
  Map<String, dynamic>? _selectedBank;
  final _accountController = TextEditingController();
  final _accountNameController = TextEditingController();
  bool _isLoading = false;
  bool _isVerifying = false;
  bool _hasAccount = false;
  bool _isLocked = false;
  bool _banksLoaded = false;
  String _statusMessage = '';

  static const List<String> _popularBankCodes = [
    '057', '044', '101', '033', '011', '070', '023', '035', '082', '076',
    '232', '032', '030', '215', '068', '014', '102', '301', '302', '090',
  ];

  static const Map<String, String> _guaranteedLogos = {
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

  String _getLogoUrl(String code, String name) {
    if (_guaranteedLogos.containsKey(code)) {
      return _guaranteedLogos[code]!;
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
    final logoUrl = _getLogoUrl(code, name);
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
            style: TextStyle(
              color: AppColors.primaryGreen,
              fontWeight: FontWeight.bold,
              fontSize: size * 0.4,
            ),
          ),
        ),
        errorWidget: (_, __, ___) => Center(
          child: Text(
            initial,
            style: TextStyle(
              color: AppColors.primaryGreen,
              fontWeight: FontWeight.bold,
              fontSize: size * 0.4,
            ),
          ),
        ),
      ),
    );
  }

  @override
  void initState() {
    super.initState();
    _loadBanks();
    _loadExistingAccount();
  }

  @override
  void dispose() {
    _accountController.dispose();
    _accountNameController.dispose();
    super.dispose();
  }

  Future<void> _loadBanks() async {
    try {
      final banks = await PaymentService.listBanks();
      if (mounted) {
        setState(() {
          _banks = banks..sort((a, b) => (a['name'] ?? '').compareTo(b['name'] ?? ''));
          _banksLoaded = true;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _banksLoaded = true;
          _statusMessage = 'Failed to load banks. Please try again.';
        });
      }
    }
  }

  Future<void> _loadExistingAccount() async {
    final userId = await AuthService.getUserId();
    if (userId.isEmpty) return;

    try {
      final account = await PaymentService.getBankAccount(userId);
      if (account != null && mounted) {
        setState(() {
          _hasAccount = true;
          _accountNameController.text = account['account_name'] ?? '';
          _accountController.text = account['account_number'] ?? '';
          final bankCode = account['bank_code'] ?? '';
          _selectedBank = _banks.isNotEmpty
              ? _banks.firstWhere((b) => b['code'] == bankCode, orElse: () => {})
              : null;
        });

        final locked = await PaymentService.isBankAccountLocked(userId);
        if (mounted) setState(() => _isLocked = locked);
      }
    } catch (e) {
      //
    }
  }

  void _openBankSelector() {
    if (_isLocked || _banks.isEmpty) return;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => _BankSelectionSheet(
        banks: _banks,
        selectedCode: _selectedBank?['code'],
        onSelect: (bank) {
          setState(() => _selectedBank = bank);
          Navigator.pop(ctx);
        },
      ),
    );
  }

  Future<void> _verifyAccount() async {
    if (_selectedBank == null || _accountController.text.length != 10) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Select a bank and enter a valid 10-digit account number'),
          backgroundColor: AppColors.warningOrange,
        ),
      );
      return;
    }

    setState(() => _isVerifying = true);

    try {
      final result = await PaymentService.verifyBankAccount(
        accountNumber: _accountController.text.trim(),
        bankCode: _selectedBank!['code'],
      );

      if (mounted) {
        setState(() {
          _accountNameController.text = result['account_name'] ?? 'Verified';
          _isVerifying = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isVerifying = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(friendlyError(e, fallback: "We couldn't confirm that account. Check the number and bank.")),
            backgroundColor: AppColors.errorRed,
          ),
        );
      }
    }
  }

  Future<void> _saveAccount() async {
    if (_selectedBank == null || _accountController.text.length != 10) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please fill in all fields correctly'),
          backgroundColor: AppColors.warningOrange,
        ),
      );
      return;
    }

    setState(() => _isLoading = true);

    try {
      final userId = await AuthService.getUserId();
      if (userId.isEmpty) throw Exception('Not logged in');

      final recipient = await PaymentService.createTransferRecipient(
        name: _accountNameController.text.isNotEmpty
            ? _accountNameController.text
            : await AuthService.getUserName(),
        accountNumber: _accountController.text.trim(),
        bankCode: _selectedBank!['code'],
      );

      await PaymentService.saveBankAccount(
        userId: userId,
        bankName: _selectedBank!['name'],
        bankCode: _selectedBank!['code'],
        accountNumber: _accountController.text.trim(),
        accountName: _accountNameController.text.isNotEmpty
            ? _accountNameController.text
            : 'Verified Account',
        recipientCode: recipient['recipient_code'],
      );

      await PaymentService.lockBankAccount(userId);

      if (mounted) {
        setState(() {
          _isLoading = false;
          _hasAccount = true;
          _isLocked = true;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Bank account saved successfully!'),
            backgroundColor: AppColors.successGreen,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isLoading = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(friendlyError(e, fallback: "We couldn't save your bank account. Please try again.")),
            backgroundColor: AppColors.errorRed,
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Bank Account'),
        backgroundColor: AppColors.primaryGreen,
        foregroundColor: Colors.white,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: AppColors.escrowBlue.withAlpha(15),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: AppColors.escrowBlue.withAlpha(40)),
              ),
              child: Row(
                children: [
                  const Icon(Icons.info_outline, color: AppColors.escrowBlue, size: 24),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      'Add your bank account to receive payments. Your account details are secured and encrypted.',
                      style: TextStyle(color: Colors.grey[700], fontSize: 13),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 24),

            if (_isLocked) ...[
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: AppColors.warningOrange.withAlpha(15),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: AppColors.warningOrange.withAlpha(40)),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.lock, color: AppColors.warningOrange, size: 24),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        'Bank account locked for 24 hours after last change. This protects against unauthorized changes.',
                        style: TextStyle(color: Colors.grey[700], fontSize: 13),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 24),
            ],

            const Text('Bank', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            GestureDetector(
              onTap: _openBankSelector,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                decoration: BoxDecoration(
                  border: Border.all(color: Colors.grey[300]!),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: _selectedBank != null
                    ? Row(
                        children: [
                          _buildBankLogo(_selectedBank!['code'] ?? '', _selectedBank!['name'] ?? ''),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              _selectedBank!['name'] ?? 'Unknown',
                              style: const TextStyle(fontSize: 14),
                            ),
                          ),
                          Icon(Icons.arrow_drop_down, color: Colors.grey[600]),
                        ],
                      )
                    : Row(
                        children: [
                          if (_banks.isEmpty)
                            const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          else
                            Icon(Icons.account_balance, color: Colors.grey[400]),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              _banks.isEmpty ? 'Loading banks...' : 'Select your bank',
                              style: TextStyle(
                                color: Colors.grey[500],
                                fontSize: 14,
                              ),
                            ),
                          ),
                          Icon(Icons.arrow_drop_down, color: Colors.grey[600]),
                        ],
                      ),
              ),
            ),
            const SizedBox(height: 20),

            const Text('Account Number', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            TextField(
              controller: _accountController,
              keyboardType: TextInputType.number,
              maxLength: 10,
              enabled: !_isLocked,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              decoration: InputDecoration(
                hintText: 'Enter 10-digit account number',
                counterText: '',
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                suffixIcon: _accountController.text.length == 10
                    ? IconButton(
                        icon: _isVerifying
                            ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                            : const Icon(Icons.search, color: AppColors.primaryGreen),
                        onPressed: _isVerifying ? null : _verifyAccount,
                      )
                    : null,
              ),
              onChanged: (val) {
                setState(() {});
                if (val.length == 10 && _selectedBank != null) {
                  _verifyAccount();
                }
              },
            ),
            const SizedBox(height: 20),

            const Text('Account Name', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            TextField(
              controller: _accountNameController,
              enabled: false,
              decoration: InputDecoration(
                hintText: 'Auto-verified from bank',
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                prefixIcon: const Icon(Icons.person_outline, color: AppColors.mediumGray),
                filled: true,
                fillColor: Colors.grey[50],
              ),
            ),
            const SizedBox(height: 32),

            SizedBox(
              width: double.infinity,
              height: 52,
              child: ElevatedButton(
                onPressed: (_isLoading || _isLocked) ? null : _saveAccount,
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.primaryGreen,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
                child: _isLoading
                    ? const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                    : Text(
                        _hasAccount ? 'Update Bank Account' : 'Save Bank Account',
                        style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                      ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _BankSelectionSheet extends StatefulWidget {
  final List<Map<String, dynamic>> banks;
  final String? selectedCode;
  final Function(Map<String, dynamic>) onSelect;

  const _BankSelectionSheet({
    required this.banks,
    required this.selectedCode,
    required this.onSelect,
  });

  @override
  State<_BankSelectionSheet> createState() => _BankSelectionSheetState();
}

class _BankSelectionSheetState extends State<_BankSelectionSheet> {
  final _searchController = TextEditingController();
  String _query = '';

  static const List<String> _popularCodes = [
    '057', '044', '101', '033', '011', '070', '023', '035', '082', '076',
  ];

  static const Map<String, String> _guaranteedLogos = {
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

  String _getLogoUrl(String code, String name) {
    if (_guaranteedLogos.containsKey(code)) {
      return _guaranteedLogos[code]!;
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

  Widget _buildLogo(String code, String name, {double size = 40}) {
    final logoUrl = _getLogoUrl(code, name);
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
            style: TextStyle(
              color: AppColors.primaryGreen,
              fontWeight: FontWeight.bold,
              fontSize: size * 0.4,
            ),
          ),
        ),
        errorWidget: (_, __, ___) => Center(
          child: Text(
            initial,
            style: TextStyle(
              color: AppColors.primaryGreen,
              fontWeight: FontWeight.bold,
              fontSize: size * 0.4,
            ),
          ),
        ),
      ),
    );
  }

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
    return widget.banks.where((b) => _popularCodes.contains(b['code'])).toList();
  }

  @override
  Widget build(BuildContext context) {
    final filtered = _filteredBanks;
    final popular = _query.isEmpty ? _popularBanks : [];
    final others = _query.isEmpty
        ? filtered.where((b) => !_popularCodes.contains(b['code'])).toList()
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
              decoration: BoxDecoration(
                color: Colors.grey[300],
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
              child: Row(
                children: [
                  const Expanded(
                    child: Text(
                      'Select Bank',
                      style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                    ),
                  ),
                  IconButton(
                    onPressed: () => Navigator.pop(ctx),
                    icon: const Icon(Icons.close),
                  ),
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
                      child: Text(
                        'POPULAR BANKS',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: Colors.grey,
                          letterSpacing: 1,
                        ),
                      ),
                    ),
                    ...popular.map((bank) => _buildBankTile(bank)),
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 12),
                      child: Divider(),
                    ),
                  ],
                  if (_query.isNotEmpty && filtered.isEmpty)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 40),
                      child: Center(
                        child: Text(
                          'No banks found',
                          style: TextStyle(color: Colors.grey, fontSize: 15),
                        ),
                      ),
                    )
                  else ...[
                    if (_query.isEmpty)
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 8),
                        child: Text(
                          'ALL BANKS',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            color: Colors.grey,
                            letterSpacing: 1,
                          ),
                        ),
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
      leading: _buildLogo(code, name),
      title: Text(
        name,
        style: TextStyle(
          fontSize: 14,
          fontWeight: isSelected ? FontWeight.w600 : FontWeight.w400,
        ),
      ),
      trailing: isSelected
          ? const Icon(Icons.check_circle, color: AppColors.primaryGreen, size: 20)
          : null,
      onTap: () => widget.onSelect(bank),
    );
  }
}
