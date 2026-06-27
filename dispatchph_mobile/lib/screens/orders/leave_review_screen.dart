import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import '../../core/blocs/review_bloc.dart';
import '../../core/services/auth_service.dart';
import '../../core/services/supabase_service.dart';

import '../../theme/app_theme.dart';

class LeaveReviewScreen extends StatefulWidget {
  final String storeId;
  final String? orderId;
  final String storeName;

  const LeaveReviewScreen({
    super.key,
    required this.storeId,
    this.orderId,
    required this.storeName,
  });

  @override
  State<LeaveReviewScreen> createState() => _LeaveReviewScreenState();
}

class _LeaveReviewScreenState extends State<LeaveReviewScreen> {
  int _rating = 0;
  int _hoverRating = 0;
  final _commentController = TextEditingController();
  bool _isSubmitting = false;

  Future<void> _submit() async {
    if (_rating == 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please select a rating'), backgroundColor: AppColors.errorRed),
      );
      return;
    }

    setState(() => _isSubmitting = true);

    final userId = await AuthService.getUserId();

    final alreadyReviewed = await context.read<ReviewCubit>().hasReviewed(
      widget.storeId,
      userId,
      orderId: widget.orderId,
    );
    if (alreadyReviewed) {
      setState(() => _isSubmitting = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('You have already reviewed this store.'),
            backgroundColor: AppColors.warningOrange,
          ),
        );
        Navigator.pop(context);
      }
      return;
    }

    final success = await context.read<ReviewCubit>().submitReview(
      storeId: widget.storeId,
      userId: userId,
      orderId: widget.orderId,
      rating: _rating,
      comment: _commentController.text.trim().isEmpty ? null : _commentController.text.trim(),
    );

    setState(() => _isSubmitting = false);

    if (mounted) {
      if (success) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Review submitted! Thank you.'),
            backgroundColor: AppColors.successGreen,
          ),
        );
        Navigator.pop(context, true);
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Failed to submit review. Please try again.'),
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
        title: const Text('Leave a Review'),
        backgroundColor: AppColors.primaryBlue,
        foregroundColor: Colors.white,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Column(
                children: [
                  const Icon(Icons.store, size: 48, color: AppColors.primaryBlue),
                  const SizedBox(height: 8),
                  Text(widget.storeName,
                      style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 4),
                  const Text('How was your experience?',
                      style: TextStyle(color: AppColors.mediumGray)),
                ],
              ),
            ),
            const SizedBox(height: 32),

            // Star rating
            const Text('Your Rating', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            const SizedBox(height: 12),
            Center(
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: List.generate(5, (i) {
                  final starNum = i + 1;
                  final filled = starNum <= (_hoverRating > 0 ? _hoverRating : _rating);
                  return GestureDetector(
                    onTap: () => setState(() => _rating = starNum),
                    onPanStart: (_) {},
                    child: MouseRegion(
                      onEnter: (_) => setState(() => _hoverRating = starNum),
                      onExit: (_) => setState(() => _hoverRating = 0),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                        child: Icon(
                          filled ? Icons.star : Icons.star_border,
                          size: 44,
                          color: filled ? AppColors.starYellow : AppColors.mediumGray,
                        ),
                      ),
                    ),
                  );
                }),
              ),
            ),
            if (_rating > 0) ...[
              const SizedBox(height: 4),
              Center(
                child: Text(
                  _ratingLabel(_rating),
                  style: const TextStyle(fontSize: 14, color: AppColors.mediumGray),
                ),
              ),
            ],
            const SizedBox(height: 24),

            // Comment
            const Text('Write a Comment (optional)', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            TextField(
              controller: _commentController,
              decoration: const InputDecoration(
                hintText: 'Share your experience with this store...',
                border: OutlineInputBorder(),
              ),
              maxLines: 4,
            ),
            const SizedBox(height: 32),

            // Submit
            SizedBox(
              width: double.infinity,
              height: 52,
              child: ElevatedButton(
                onPressed: _isSubmitting ? null : _submit,
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.starYellow,
                  foregroundColor: AppColors.charcoal,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
                child: _isSubmitting
                    ? const SizedBox(
                        height: 24,
                        width: 24,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('Submit Review', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _ratingLabel(int r) {
    switch (r) {
      case 1: return 'Poor';
      case 2: return 'Fair';
      case 3: return 'Good';
      case 4: return 'Very Good';
      case 5: return 'Excellent';
      default: return '';
    }
  }
}
