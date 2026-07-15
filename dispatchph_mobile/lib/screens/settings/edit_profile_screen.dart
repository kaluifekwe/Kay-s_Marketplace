import 'package:flutter/material.dart';
import '../../theme/app_theme.dart';
import '../../widgets/phone_input.dart';
import '../../widgets/primary_button.dart';
import '../../core/services/auth_service.dart';

/// Lets a signed-in user edit their name and contact phone. The phone is the
/// number couriers call for pickup/delivery, so it's required and validated.
class EditProfileScreen extends StatefulWidget {
  const EditProfileScreen({super.key});

  @override
  State<EditProfileScreen> createState() => _EditProfileScreenState();
}

class _EditProfileScreenState extends State<EditProfileScreen> {
  final _nameController = TextEditingController();
  final _phoneController = TextEditingController();
  bool _loading = true;
  bool _saving = false;
  String? _phoneError;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _nameController.dispose();
    _phoneController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final data = await AuthService.loadProfile();
    if (!mounted) return;
    setState(() {
      _nameController.text = data['name'] ?? '';
      _phoneController.text = data['phone'] ?? '';
      _loading = false;
    });
  }

  Future<void> _save() async {
    final name = _nameController.text.trim();
    if (name.isEmpty) {
      _snack('Enter your full name');
      return;
    }
    if (!PhoneInputField.isValid(_phoneController.text)) {
      setState(() => _phoneError = 'Enter a valid 11-digit number (e.g. 08012345678)');
      return;
    }
    setState(() {
      _phoneError = null;
      _saving = true;
    });
    final err = await AuthService.updateProfile(name: name, phone: _phoneController.text.trim());
    if (!mounted) return;
    setState(() => _saving = false);
    if (err != null) {
      _snack(err);
      return;
    }
    _snack('Profile updated');
    Navigator.pop(context, true);
  }

  void _snack(String msg) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.white,
      appBar: AppBar(title: const Text('Edit Profile')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : SafeArea(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Full name', style: TextStyle(fontWeight: FontWeight.w600)),
                    const SizedBox(height: 8),
                    TextField(
                      controller: _nameController,
                      decoration: const InputDecoration(hintText: 'e.g., Okonkwo Chibueze'),
                    ),
                    const SizedBox(height: 20),
                    const Text('Phone number', style: TextStyle(fontWeight: FontWeight.w600)),
                    const SizedBox(height: 8),
                    PhoneInputField(controller: _phoneController, errorText: _phoneError),
                    const SizedBox(height: 6),
                    Text(
                      'This is the number couriers will call for pickup and delivery.',
                      style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                    ),
                    const SizedBox(height: 32),
                    PrimaryButton(
                      text: 'Save Changes',
                      isLoading: _saving,
                      onPressed: _save,
                      backgroundColor: AppColors.primaryGreen,
                    ),
                  ],
                ),
              ),
            ),
    );
  }
}
