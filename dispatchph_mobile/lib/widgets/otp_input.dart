import 'package:flutter/material.dart';
import 'package:pin_code_fields/pin_code_fields.dart';
import '../theme/app_theme.dart';

class OtpInputField extends StatelessWidget {
  final TextEditingController controller;
  final String? errorText;
  final VoidCallback? onCompleted;

  const OtpInputField({
    super.key,
    required this.controller,
    this.errorText,
    this.onCompleted,
  });

  @override
  Widget build(BuildContext context) {
    return PinCodeTextField(
      appContext: context,
      length: 6,
      controller: controller,
      keyboardType: TextInputType.number,
      pinTheme: PinTheme(
        shape: PinCodeFieldShape.box,
        borderRadius: BorderRadius.circular(12),
        fieldHeight: 50,
        fieldWidth: 45,
        activeFillColor: AppColors.lightGray,
        inactiveFillColor: AppColors.lightGray,
        selectedFillColor: AppColors.lightGray,
        activeColor: AppColors.primaryGreen,
        inactiveColor: AppColors.mediumGray,
        selectedColor: AppColors.riderYellow,
      ),
      onCompleted: (_) => onCompleted?.call(),
    );
  }
}
