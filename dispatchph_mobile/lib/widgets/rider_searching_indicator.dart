import 'package:flutter/material.dart';
import '../theme/app_theme.dart';

/// Animated "we're finding you a rider" indicator shown while courier rates
/// load at checkout. A brand-green ring sweeps around a motorbike icon (so it
/// clearly reads as *searching for a rider*), with a reassuring message and an
/// animated ellipsis. Purely visual — drop it in wherever quotes are loading.
class RiderSearchingIndicator extends StatefulWidget {
  final String message;
  const RiderSearchingIndicator({
    super.key,
    this.message = 'Searching for available riders',
  });

  @override
  State<RiderSearchingIndicator> createState() => _RiderSearchingIndicatorState();
}

class _RiderSearchingIndicatorState extends State<RiderSearchingIndicator>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 1400))
        ..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    const green = AppColors.primaryGreen;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Row(
        children: [
          SizedBox(
            width: 34,
            height: 34,
            child: Stack(
              alignment: Alignment.center,
              children: const [
                // Sweeping ring = "searching".
                SizedBox(
                  width: 34,
                  height: 34,
                  child: CircularProgressIndicator(
                    strokeWidth: 2.6,
                    valueColor: AlwaysStoppedAnimation(green),
                  ),
                ),
                // Static rider in the middle so it reads as "a rider".
                Icon(Icons.two_wheeler, size: 17, color: green),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                AnimatedBuilder(
                  animation: _c,
                  builder: (context, _) {
                    final n = 1 + ((_c.value * 3).floor() % 3);
                    return Text(
                      '${widget.message}${'.' * n}',
                      style: const TextStyle(
                        fontSize: 13.5,
                        fontWeight: FontWeight.w600,
                        color: green,
                      ),
                    );
                  },
                ),
                const SizedBox(height: 2),
                Text(
                  'Please hold on a moment',
                  style: TextStyle(fontSize: 11.5, color: Colors.grey[600]),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
