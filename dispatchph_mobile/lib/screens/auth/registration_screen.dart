import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../theme/app_theme.dart';
import '../../widgets/primary_button.dart';
import '../../core/services/auth_service.dart';
import '../../core/services/supabase_service.dart';
import '../../core/services/store_service.dart';
import '../../core/constants/nigerian_states.dart';
import 'home_router.dart';

class RegistrationScreen extends StatefulWidget {
  final String userType;

  const RegistrationScreen({super.key, required this.userType});

  @override
  State<RegistrationScreen> createState() => _RegistrationScreenState();
}

class _RegistrationScreenState extends State<RegistrationScreen> {
  final _nameController = TextEditingController();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _confirmPasswordController = TextEditingController();
  final _addressController = TextEditingController();
  final _storeNameController = TextEditingController();
  final _storeDescController = TextEditingController();
  final _storePhoneController = TextEditingController();
  bool _obscurePassword = true;
  bool _isLoading = false;
  String? _selectedState;

  bool get _isVendor => widget.userType == 'vendor';

  @override
  void dispose() {
    _nameController.dispose();
    _emailController.dispose();
    _passwordController.dispose();
    _confirmPasswordController.dispose();
    _addressController.dispose();
    _storeNameController.dispose();
    _storeDescController.dispose();
    _storePhoneController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_nameController.text.trim().isEmpty) {
      _showError('Enter your full name');
      return;
    }
    if (_emailController.text.trim().isEmpty || !_emailController.text.contains('@')) {
      _showError('Enter a valid email address');
      return;
    }
    if (_passwordController.text.length < 6) {
      _showError('Password must be at least 6 characters');
      return;
    }
    if (_passwordController.text != _confirmPasswordController.text) {
      _showError('Passwords do not match');
      return;
    }
    if (_isVendor && _storeNameController.text.trim().isEmpty) {
      _showError('Enter your store name');
      return;
    }
    if (_selectedState == null) {
      _showError('Please select your state');
      return;
    }

    setState(() => _isLoading = true);

    try {
      // Step 1: Register auth user first
      final regSuccess = await AuthService.register(
        email: _emailController.text.trim(),
        password: _passwordController.text,
        name: _nameController.text.trim(),
        role: widget.userType,
        address: _addressController.text.trim().isEmpty
            ? null
            : _addressController.text.trim(),
        state: _selectedState,
      );

      if (!mounted) return;

      if (!regSuccess) {
        setState(() => _isLoading = false);
        _showError('Email already registered. Please log in instead.');
        return;
      }

      // Step 2: Get the Supabase Auth user ID
      final userId = await AuthService.getUserId();
      print('[Registration] Auth user created: userId=$userId');

      // Step 3: For vendors, create store with correct vendor_id
      if (_isVendor) {
        final storeId = const Uuid().v4();
        final storeName = _storeNameController.text.trim();
        final handle = await StoreService.generateUniqueHandle(storeName);
        print('[Registration] Creating store: storeId=$storeId vendorId=$userId handle=$handle');

        await SupabaseService.client.from('stores').insert({
          'id': storeId,
          'vendor_id': userId,
          'name': storeName,
          'handle': handle,
          'description': _storeDescController.text.trim().isEmpty
              ? null
              : _storeDescController.text.trim(),
          'phone': _storePhoneController.text.trim().isEmpty
              ? null
              : _storePhoneController.text.trim(),
          'address': _addressController.text.trim().isEmpty
              ? null
              : _addressController.text.trim(),
        });

        // Step 4: Link store to user
        await SupabaseService.client
            .from('users')
            .update({'store_id': storeId}).eq('id', userId);

        // Update local prefs
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('auth_store_id', storeId);

        print('[Registration] Store created and linked');
      }

      if (!mounted) return;
      setState(() => _isLoading = false);

      if (_isVendor) {
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(builder: (_) => const HomeRouter(role: 'vendor')),
        );
      } else {
        // Policy gate comes first; the welcome-credit dialog shows on the home
        // screen once the buyer has accepted.
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(
            builder: (_) => const HomeRouter(role: 'buyer', showWelcomeCredit: true),
          ),
        );
      }
    } catch (e) {
      print('[Registration] Error: $e');
      if (mounted) {
        setState(() => _isLoading = false);
        _showError('Registration failed: $e');
      }
    }
  }

  void _showError(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.white,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        foregroundColor: AppColors.charcoal,
        title: Text(_isVendor ? 'Vendor Registration' : 'Create Account'),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                _isVendor ? 'Open your store' : 'Join as a buyer',
                style: Theme.of(context).textTheme.headlineLarge,
              ),
              const SizedBox(height: 8),
              Text(
                _isVendor
                    ? 'Fill in your details to start selling'
                    : 'Fill in your details to start shopping',
                style: Theme.of(context).textTheme.bodyLarge?.copyWith(color: AppColors.mediumGray),
              ),
              const SizedBox(height: 24),
              TextField(
                controller: _nameController,
                decoration: const InputDecoration(labelText: 'Full name', hintText: 'e.g., Okonkwo Chibueze'),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _emailController,
                keyboardType: TextInputType.emailAddress,
                decoration: const InputDecoration(
                  labelText: 'Email address',
                  hintText: 'e.g., chibueze@email.com',
                ),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _passwordController,
                obscureText: _obscurePassword,
                decoration: InputDecoration(
                  labelText: 'Password',
                  suffixIcon: IconButton(
                    icon: Icon(_obscurePassword ? Icons.visibility_off : Icons.visibility),
                    onPressed: () => setState(() => _obscurePassword = !_obscurePassword),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _confirmPasswordController,
                obscureText: true,
                decoration: const InputDecoration(labelText: 'Confirm password'),
              ),
              if (_isVendor) ...[
                const SizedBox(height: 16),
                TextField(
                  controller: _storeNameController,
                  decoration: const InputDecoration(labelText: 'Store name', hintText: 'e.g., Chibueze Stores'),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: _storeDescController,
                  maxLines: 3,
                  decoration: const InputDecoration(
                    labelText: 'Store description',
                    hintText: 'Tell buyers about your store',
                  ),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: _storePhoneController,
                  keyboardType: TextInputType.phone,
                  decoration: const InputDecoration(
                    labelText: 'Store phone number',
                    hintText: '080XXXXXXXX',
                  ),
                ),
              ],
              const SizedBox(height: 16),
              TextField(
                controller: _addressController,
                decoration: const InputDecoration(
                  labelText: 'Address',
                  hintText: 'e.g., 14 Eneka Road, Rumuokoro',
                ),
              ),
              const SizedBox(height: 16),
              DropdownButtonFormField<String>(
                decoration: InputDecoration(
                  labelText: 'Your State',
                  prefixIcon: const Icon(Icons.location_on, color: AppColors.primaryGreen),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                ),
                hint: const Text('Select your state'),
                value: _selectedState,
                items: nigerianStates
                    .map((state) => DropdownMenuItem(value: state, child: Text(state)))
                    .toList(),
                validator: (value) => value == null ? 'Please select your state' : null,
                onChanged: (value) => setState(() => _selectedState = value),
              ),
              Padding(
                padding: const EdgeInsets.only(top: 6, left: 4),
                child: Text(
                  _isVendor
                      ? '📍 Buyers in other states will not be able to purchase from your store'
                      : '📍 You can only purchase from vendors in your state',
                  style: TextStyle(fontSize: 11, color: Colors.grey[600]),
                ),
              ),
              const SizedBox(height: 32),
              PrimaryButton(
                text: _isVendor ? 'Open Store' : 'Create Account',
                isLoading: _isLoading,
                onPressed: _submit,
                backgroundColor: AppColors.primaryGreen,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
