import 'package:flutter/material.dart';
import '../theme/app_theme.dart';

/// Live password feedback shown under a password field during sign-up.
/// Combines a strength bar (Weak → Strong) with a short checklist of what's
/// still missing, so the user sees both *how strong* and *exactly how to
/// improve*. Renders nothing until the user starts typing.
///
/// Policy (kept gentle to avoid sign-up friction): the password is accepted
/// once it has 8+ characters AND both letters and numbers. A symbol is only
/// needed to reach the "Strong" rating — never required. Use
/// [PasswordStrengthIndicator.isAcceptable] to gate submission with the same
/// rule the UI shows.
class PasswordStrengthIndicator extends StatelessWidget {
  final String password;

  const PasswordStrengthIndicator({super.key, required this.password});

  static bool hasMinLength(String p) => p.length >= 8;
  static bool hasLettersAndNumbers(String p) =>
      RegExp(r'[A-Za-z]').hasMatch(p) && RegExp(r'\d').hasMatch(p);
  static bool hasSymbol(String p) => RegExp(r'[^A-Za-z0-9]').hasMatch(p);

  /// The hard rule that gates sign-up — mirrors the two required checklist rows.
  static bool isAcceptable(String p) => hasMinLength(p) && hasLettersAndNumbers(p);

  /// 0 (empty) .. 4 (strong). Length, mixed letters+numbers, a symbol, and a
  /// bonus for a genuinely long password each add a point.
  int get _score {
    if (password.isEmpty) return 0;
    var s = 0;
    if (hasMinLength(password)) s++;
    if (hasLettersAndNumbers(password)) s++;
    if (hasSymbol(password)) s++;
    if (password.length >= 12) s++;
    return s;
  }

  @override
  Widget build(BuildContext context) {
    if (password.isEmpty) return const SizedBox.shrink();

    final score = _score;
    // Map the 0-4 score to a label + colour. A password that isn't yet
    // acceptable can never read above "Weak", so the bar never over-promises.
    final acceptable = isAcceptable(password);
    late final String label;
    late final Color color;
    late final int filledBars;
    if (!acceptable) {
      label = 'Weak';
      color = AppColors.errorRed;
      filledBars = 1;
    } else if (score <= 2) {
      label = 'Fair';
      color = Colors.orange;
      filledBars = 2;
    } else if (score == 3) {
      label = 'Good';
      color = Colors.amber.shade700;
      filledBars = 3;
    } else {
      label = 'Strong';
      color = AppColors.successGreen;
      filledBars = 4;
    }

    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              for (var i = 0; i < 4; i++) ...[
                Expanded(
                  child: Container(
                    height: 5,
                    decoration: BoxDecoration(
                      color: i < filledBars ? color : Colors.grey.shade300,
                      borderRadius: BorderRadius.circular(3),
                    ),
                  ),
                ),
                if (i < 3) const SizedBox(width: 6),
              ],
            ],
          ),
          const SizedBox(height: 6),
          Text(
            'Password strength: $label',
            style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: color),
          ),
          const SizedBox(height: 8),
          _rule('At least 8 characters', hasMinLength(password)),
          _rule('Letters and numbers', hasLettersAndNumbers(password)),
          _rule('A symbol (e.g. ! @ #) — stronger', hasSymbol(password), optional: true),
        ],
      ),
    );
  }

  Widget _rule(String text, bool met, {bool optional = false}) {
    final Color iconColor = met
        ? AppColors.successGreen
        : (optional ? AppColors.mediumGray : AppColors.mediumGray);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Icon(
            met ? Icons.check_circle : (optional ? Icons.circle_outlined : Icons.radio_button_unchecked),
            size: 15,
            color: iconColor,
          ),
          const SizedBox(width: 6),
          Text(
            text,
            style: TextStyle(
              fontSize: 12,
              color: met ? AppColors.charcoal : AppColors.mediumGray,
            ),
          ),
        ],
      ),
    );
  }
}
