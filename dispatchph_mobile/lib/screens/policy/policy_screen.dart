import 'package:flutter/material.dart';
import '../../theme/app_theme.dart';
import '../../core/constants/app_policy.dart';
import '../../core/services/policy_service.dart';
import '../../core/services/supabase_service.dart';

/// Renders the Buyer & Vendor Agreement content. Shared by the acceptance gate
/// and the read-only [PolicyScreen] so the wording lives in exactly one place
/// (app_policy.dart).
class PolicyBody extends StatelessWidget {
  const PolicyBody({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(kPolicyTitle, style: theme.textTheme.titleLarge),
        const SizedBox(height: 4),
        Text(
          kPolicyEffective,
          style: theme.textTheme.bodySmall?.copyWith(color: AppColors.mediumGray),
        ),
        const SizedBox(height: 16),
        Text(
          kPolicyIntro,
          style: theme.textTheme.bodyMedium?.copyWith(color: AppColors.mediumGray),
        ),
        for (final block in kPolicyBlocks) ...[
          const SizedBox(height: 20),
          if (block.heading != null)
            Text(block.heading!, style: theme.textTheme.titleMedium),
          if (block.body != null) ...[
            const SizedBox(height: 6),
            Text(block.body!, style: theme.textTheme.bodyMedium),
          ],
          for (final bullet in block.bullets) ...[
            const SizedBox(height: 8),
            _Bullet(text: bullet),
          ],
        ],
        const SizedBox(height: 24),
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: AppColors.primaryGreen.withAlpha(15),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Text(
            kPolicyClosing,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: AppColors.primaryGreen,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ],
    );
  }
}

/// A bullet point. If the text begins with a "lead-in — rest" phrase, the
/// lead-in is bolded to match the written agreement.
class _Bullet extends StatelessWidget {
  final String text;
  const _Bullet({required this.text});

  @override
  Widget build(BuildContext context) {
    final base = Theme.of(context).textTheme.bodyMedium;
    final dashIndex = text.indexOf(' — ');
    final InlineSpan content;
    if (dashIndex > 0) {
      content = TextSpan(children: [
        TextSpan(
          text: text.substring(0, dashIndex),
          style: const TextStyle(fontWeight: FontWeight.w700),
        ),
        TextSpan(text: text.substring(dashIndex)),
      ]);
    } else {
      content = TextSpan(text: text);
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Padding(
          padding: EdgeInsets.only(top: 7, right: 8),
          child: Icon(Icons.circle, size: 6, color: AppColors.primaryGreen),
        ),
        Expanded(child: Text.rich(content, style: base)),
      ],
    );
  }
}

/// Read-only view of the agreement, opened from the buyer/vendor profile.
class PolicyScreen extends StatelessWidget {
  const PolicyScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final userId = SupabaseService.auth.currentUser?.id;
    return Scaffold(
      backgroundColor: AppColors.white,
      appBar: AppBar(title: const Text('Terms & Policy')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (userId != null)
              FutureBuilder<DateTime?>(
                future: PolicyService.acceptedAt(userId),
                builder: (context, snap) {
                  final at = snap.data;
                  if (at == null) return const SizedBox.shrink();
                  final d = '${at.day.toString().padLeft(2, '0')}/'
                      '${at.month.toString().padLeft(2, '0')}/${at.year}';
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 16),
                    child: Row(
                      children: [
                        const Icon(Icons.verified_user,
                            size: 18, color: AppColors.primaryGreen),
                        const SizedBox(width: 8),
                        Text(
                          'Accepted on $d',
                          style: const TextStyle(
                            color: AppColors.primaryGreen,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
            const PolicyBody(),
          ],
        ),
      ),
    );
  }
}
