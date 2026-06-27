import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:uuid/uuid.dart';
import '../services/supabase_service.dart';
import '../models/models.dart';

class ReviewCubit extends Cubit<ReviewState> {
  ReviewCubit() : super(ReviewState());

  final _uuid = const Uuid();

  /// Load reviews for a store. The displayed list is capped to the most
  /// recent 50 (unbounded growth here would mean fetching a store's entire
  /// review history on every screen open). Average rating/count are fetched
  /// separately via an aggregate query so they stay accurate for stores
  /// with more than 50 reviews.
  Future<void> loadStoreReviews(String storeId) async {
    emit(state.copyWith(isLoading: true));
    try {
      final data = await SupabaseService.client
          .from('reviews')
          .select('*, users(name)')
          .eq('store_id', storeId)
          .order('created_at', ascending: false)
          .limit(50);

      final reviews = (data as List).map((r) => Review.fromJson(r)).toList();

      double avg = _calculateAverage(reviews);
      int count = reviews.length;
      try {
        final stats = await SupabaseService.client
            .rpc('get_store_review_stats', params: {'p_store_id': storeId});
        if (stats is List && stats.isNotEmpty) {
          avg = (stats.first['avg_rating'] as num?)?.toDouble() ?? avg;
          count = (stats.first['review_count'] as num?)?.toInt() ?? count;
        }
      } catch (e) {
        print('[ReviewCubit] get_store_review_stats error: $e');
      }

      emit(state.copyWith(
        isLoading: false,
        reviews: reviews,
        averageRating: avg,
        reviewCount: count,
      ));
    } catch (e) {
      print('[ReviewCubit] loadStoreReviews error: $e');
      emit(state.copyWith(isLoading: false));
    }
  }

  /// Submit a review
  Future<bool> submitReview({
    required String storeId,
    required String userId,
    required String? orderId,
    required int rating,
    required String? comment,
  }) async {
    emit(state.copyWith(isSubmitting: true));
    try {
      await SupabaseService.client.from('reviews').insert({
        'store_id': storeId,
        'user_id': userId,
        'order_id': orderId,
        'rating': rating,
        'comment': comment,
      });

      emit(state.copyWith(isSubmitting: false));
      return true;
    } catch (e) {
      print('[ReviewCubit] submitReview error: $e');
      emit(state.copyWith(isSubmitting: false));
      return false;
    }
  }

  /// Check if user already reviewed a store for an order
  Future<bool> hasReviewed(String storeId, String userId, {String? orderId}) async {
    try {
      var query = SupabaseService.client
          .from('reviews')
          .select('id')
          .eq('store_id', storeId)
          .eq('user_id', userId);

      if (orderId != null) {
        query = query.eq('order_id', orderId);
      }

      final result = await query;
      final count = (result as List).length;
      return count > 0;
    } catch (e) {
      print('[ReviewCubit] hasReviewed error: $e');
      return false;
    }
  }

  double _calculateAverage(List<Review> reviews) {
    if (reviews.isEmpty) return 0;
    final sum = reviews.fold<int>(0, (total, r) => total + r.rating);
    return sum / reviews.length;
  }
}

class ReviewState {
  final bool isLoading;
  final bool isSubmitting;
  final List<Review> reviews;
  final double averageRating;
  final int reviewCount;

  ReviewState({
    this.isLoading = false,
    this.isSubmitting = false,
    this.reviews = const [],
    this.averageRating = 0,
    this.reviewCount = 0,
  });

  ReviewState copyWith({
    bool? isLoading,
    bool? isSubmitting,
    List<Review>? reviews,
    double? averageRating,
    int? reviewCount,
  }) {
    return ReviewState(
      isLoading: isLoading ?? this.isLoading,
      isSubmitting: isSubmitting ?? this.isSubmitting,
      reviews: reviews ?? this.reviews,
      averageRating: averageRating ?? this.averageRating,
      reviewCount: reviewCount ?? this.reviewCount,
    );
  }
}
