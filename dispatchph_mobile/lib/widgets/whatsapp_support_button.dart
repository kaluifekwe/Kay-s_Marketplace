import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

/// A prominent, gently-pulsing "Chat support" button that opens a WhatsApp chat
/// with Kays Market support. Reused on the buyer marketplace and the vendor
/// dashboard so help is always one tap away. Pure Dart (url_launcher) — ships in
/// a Shorebird patch, no native rebuild.
class WhatsAppSupportButton extends StatefulWidget {
  const WhatsAppSupportButton({super.key});

  // Kays Market support line: +234 802 838 7709. wa.me wants digits only.
  static const String supportNumber = '2348028387709';

  @override
  State<WhatsAppSupportButton> createState() => _WhatsAppSupportButtonState();
}

class _WhatsAppSupportButtonState extends State<WhatsAppSupportButton>
    with SingleTickerProviderStateMixin {
  static const Color _waGreen = Color(0xFF25D366); // WhatsApp brand green
  late final AnimationController _pulse;

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(vsync: this, duration: const Duration(milliseconds: 1500))
      ..repeat(reverse: true);
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  Future<void> _openWhatsApp() async {
    const message = "Hi Kay's Market support, I need some help.";
    final uri = Uri.parse(
      'https://wa.me/${WhatsAppSupportButton.supportNumber}?text=${Uri.encodeComponent(message)}',
    );
    try {
      final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (!ok && mounted) await launchUrl(uri);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not open WhatsApp. Please try again.')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: _openWhatsApp,
      child: AnimatedBuilder(
        animation: _pulse,
        builder: (context, child) {
          // Subtle breathing scale + glow to draw the eye without being annoying.
          final t = Curves.easeInOut.transform(_pulse.value);
          return Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(30),
              boxShadow: [
                BoxShadow(
                  color: _waGreen.withOpacity(0.35 + 0.25 * t),
                  blurRadius: 12 + 8 * t,
                  spreadRadius: 1 + 2 * t,
                  offset: const Offset(0, 3),
                ),
              ],
            ),
            child: Transform.scale(scale: 1 + 0.03 * t, child: child),
          );
        },
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: BoxDecoration(
            color: _waGreen,
            borderRadius: BorderRadius.circular(30),
          ),
          child: const Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.chat, color: Colors.white, size: 22),
              SizedBox(width: 8),
              Text(
                'Chat support',
                style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
