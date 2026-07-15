import 'package:flutter/material.dart';
import '../theme/app_theme.dart';

class PhoneInputField extends StatelessWidget {
  final TextEditingController controller;
  final String? errorText;

  const PhoneInputField({
    super.key,
    required this.controller,
    this.errorText,
  });

  /// A valid Nigerian mobile number: 11 digits starting with 0 (e.g. 08012345678).
  static bool isValid(String raw) {
    final d = raw.replaceAll(RegExp(r'\D'), '');
    return d.length == 11 && d.startsWith('0');
  }

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      keyboardType: TextInputType.phone,
      maxLength: 11,
      decoration: InputDecoration(
        hintText: '080XXXXXXXX',
        helperText: 'Enter your 11-digit number, e.g. 08012345678',
        prefixIcon: const Icon(Icons.phone, size: 20, color: AppColors.mediumGray),
        errorText: errorText,
        counterText: '',
      ),
    );
  }
}
