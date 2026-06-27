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

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      keyboardType: TextInputType.phone,
      maxLength: 11,
      decoration: InputDecoration(
        hintText: '080XXXXXXXX',
        prefixIcon: const Padding(
          padding: EdgeInsets.only(left: 16, right: 8),
          child: Text(
            '+234',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w600,
              color: AppColors.mediumGray,
            ),
          ),
        ),
        prefixIconConstraints: const BoxConstraints(minWidth: 60),
        errorText: errorText,
        counterText: '',
      ),
    );
  }
}
