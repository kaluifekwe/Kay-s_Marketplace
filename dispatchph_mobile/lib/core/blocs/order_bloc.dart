import 'dart:async';
import 'dart:convert';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../services/supabase_service.dart';
import '../services/escrow_service.dart';
import '../services/push_service.dart';
import '../services/storage_service.dart';
import '../services/payment_service.dart';
import '../services/credit_service.dart';
import '../models/models.dart';
import 'notification_bloc.dart';

/// Returned by [OrderCubit.cancelOrder] when the buyer has no verified bank
/// account. Refunds are paid out to the buyer's bank, so the UI should offer to
/// add one rather than just showing this as a failure.
const String kNoBankAccountError =
    'Add and verify your bank account first — that is where your refund is paid.';

class OrderCubit extends Cubit<OrderState> {
  final EscrowService _escrow;
  RealtimeChannel? _ordersChannel;

  OrderCubit(this._escrow) : super(OrderState());

  void subscribeToBuyerOrders(String buyerId) {
    _ordersChannel?.unsubscribe();
    _ordersChannel = SupabaseService.client
        .channel('buyer_orders:$buyerId')
        .onPostgresChanges(
          event: PostgresChangeEvent.update,
          schema: 'public',
          table: 'orders',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'buyer_id',
            value: buyerId,
          ),
          callback: (_) => loadBuyerOrders(buyerId),
        )
        .subscribe();
  }

  void unsubscribeOrders() {
    _ordersChannel?.unsubscribe();
    _ordersChannel = null;
  }

  Future<void> createOrder({
    required String buyerId,
    required String vendorId,
    required String storeId,
    required List<Map<String, dynamic>> items,
    required double total,
  }) async {
    final id = _escrow.generateId();

    try {
      await SupabaseService.client.from('orders').insert({
        'id': id,
        'buyer_id': buyerId,
        'vendor_id': vendorId,
        'store_id': storeId,
        'items': jsonEncode(items),
        'total': total,
        'status': 'paid',
        'paid_at': DateTime.now().toIso8601String(),
      });

      final buyerProfile = await SupabaseService.client
          .from('users')
          .select('name')
          .eq('id', buyerId)
          .maybeSingle();

      // Notify the vendor via push only (no local notification on the buyer's
      // device, which performed this action).
      PushService.sendPush(
        userId: vendorId,
        title: 'New Order!',
        body: 'You received a new order of ₦${total.toStringAsFixed(0)} from ${buyerProfile?['name'] ?? 'a buyer'}',
        data: {'type': 'order', 'orderId': id},
      );

      await NotificationCubit.create(
        userId: vendorId,
        title: 'New Order Received',
        body: 'You received a new order of ₦${total.toStringAsFixed(0)} from ${buyerProfile?['name'] ?? 'a buyer'}',
        type: 'vendor_order',
        referenceId: id,
      );

      await NotificationCubit.create(
        userId: buyerId,
        title: 'Payment Confirmed',
        body: 'Your payment of ₦${total.toStringAsFixed(0)} has been confirmed. Order #$id',
        type: 'order',
        referenceId: id,
      );

      await loadBuyerOrders(buyerId);
    } catch (e) {
      print('[OrderCubit] createOrder error: $e');
    }
  }

  Future<void> loadBuyerOrders(String buyerId) async {
    emit(state.copyWith(isLoading: true));
    try {
      final data = await SupabaseService.client
          .from('orders')
          .select('id, buyer_id, vendor_id, store_id, items, total, status, payment_reference, shipping_method, tracking_ref, rider_name, rider_phone, delivery_method, shipping_proof_url, delivery_photo_url, payment_released, paid_at, shipped_at, delivered_at, confirmed_at, auto_release_at, refunded_at, created_at, delivery_type, delivery_fee, vendor_delivery_contribution, total_with_delivery, has_shipbubble_delivery, delivery_id, pickup_deadline')
          .eq('buyer_id', buyerId)
          .order('created_at', ascending: false)
          .limit(100);

      final orders = (data as List).map((o) => Order.fromJson(o)).toList();
      _rescheduleAutoReleaseTimers(orders);
      emit(state.copyWith(isLoading: false, buyerOrders: orders));
    } catch (e) {
      print('[OrderCubit] loadBuyerOrders error: $e');
      emit(state.copyWith(isLoading: false));
    }
  }

  Future<void> loadVendorOrders(String vendorId) async {
    emit(state.copyWith(isLoading: true));
    try {
      final data = await SupabaseService.client
          .from('orders')
          .select('id, buyer_id, vendor_id, store_id, items, total, status, payment_reference, shipping_method, tracking_ref, rider_name, rider_phone, delivery_method, shipping_proof_url, delivery_photo_url, payment_released, paid_at, shipped_at, delivered_at, confirmed_at, auto_release_at, refunded_at, created_at, delivery_type, delivery_fee, vendor_delivery_contribution, total_with_delivery, has_shipbubble_delivery, delivery_id, pickup_deadline')
          .eq('vendor_id', vendorId)
          .order('created_at', ascending: false)
          .limit(100);

      final orders = (data as List).map((o) => Order.fromJson(o)).toList();
      _rescheduleAutoReleaseTimers(orders);
      emit(state.copyWith(isLoading: false, vendorOrders: orders));
    } catch (e) {
      print('[OrderCubit] loadVendorOrders error: $e');
      emit(state.copyWith(isLoading: false));
    }
  }

  /// Vendor marks order as shipped — auto-release timer starts NOW (24h)
  Future<void> markShipped({
    required String orderId,
    required String vendorId,
    required String riderName,
    required String riderPhone,
    required String deliveryMethod,
    String? shippingProofPath,
  }) async {
    emit(state.copyWith(isSubmitting: true));
    try {
      String? shippingProofUrl;
      if (shippingProofPath != null) {
        shippingProofUrl = await StorageService.uploadShippingProof(
          orderId: orderId,
          filePath: shippingProofPath,
        );
      }

      final autoReleaseAt = _escrow.calculateAutoReleaseAt();

      _escrow.cancelAutoRelease(orderId);
      _escrow.scheduleAutoRelease(
        orderId: orderId,
        deadline: autoReleaseAt,
        onRelease: () => _autoRelease(orderId),
      );

      await SupabaseService.client.from('orders').update({
        'status': 'shipped',
        'shipped_at': DateTime.now().toIso8601String(),
        'rider_name': riderName,
        'rider_phone': riderPhone,
        'delivery_method': deliveryMethod,
        'shipping_proof_url': shippingProofUrl,
        'auto_release_at': autoReleaseAt.toIso8601String(),
      }).eq('id', orderId);

      final orderData = await SupabaseService.client
          .from('orders').select('buyer_id').eq('id', orderId).maybeSingle();
      if (orderData != null) {
        PushService.sendPush(
          userId: orderData['buyer_id'] as String,
          title: 'Order Shipped',
          body: 'Your order #$orderId has been shipped',
          data: {'type': 'order', 'orderId': orderId},
        );

        await NotificationCubit.create(
          userId: orderData['buyer_id'] as String,
          title: 'Order Shipped',
          body: 'Your order has been shipped and is on its way',
          type: 'order',
          referenceId: orderId,
        );
      }

      await loadVendorOrders(vendorId);
      emit(state.copyWith(isSubmitting: false));
    } catch (e) {
      print('[OrderCubit] markShipped error: $e');
      emit(state.copyWith(isSubmitting: false));
    }
  }

  /// Buyer confirms delivery with photo evidence — payment released immediately
  Future<bool> confirmDelivery({
    required String orderId,
    required String buyerId,
    String? deliveryPhotoPath,
  }) async {
    emit(state.copyWith(isSubmitting: true));
    try {
      // The photo is EVIDENCE, not a gate. Requiring it meant a buyer holding
      // the goods had to photograph them before they could say so, and the ones
      // who wouldn't bother fell silent instead — which pushed the order down
      // the 24h escalation path and made "no confirmation" look like a delivery
      // problem when it was really an upload problem. A failed upload no longer
      // blocks the confirmation either; losing the photo is better than
      // stranding an order whose buyer has told us it arrived.
      String? deliveryPhotoUrl;
      if (deliveryPhotoPath != null) {
        deliveryPhotoUrl = await StorageService.uploadDeliveryConfirmation(
          orderId: orderId,
          filePath: deliveryPhotoPath,
        );
      }

      _escrow.cancelAutoRelease(orderId);

      // Confirming means "I checked it, this is what I paid for" — it CLOSES
      // the single inspection window opened at ship time (auto_release_at),
      // it must never open a fresh one. See checkDisputeEligibility().
      await SupabaseService.client.from('orders').update({
        'status': 'confirmed',
        'confirmed_at': DateTime.now().toIso8601String(),
        'delivery_photo_url': deliveryPhotoUrl,
        'delivery_confirmed_at': DateTime.now().toIso8601String(),
        'has_dispute': false,
      }).eq('id', orderId);

      // Release escrow via Edge Function (vendor_id read from order in DB)
      try {
        await PaymentService.releaseEscrow(orderId: orderId);
      } catch (e) {
        print('[OrderCubit] releaseEscrow Edge Function error: $e');
      }

      // Award cashback to buyer
      try {
        final cashbackResult = await CreditService.awardCashback(
          orderId: orderId,
          buyerId: buyerId,
        );
        if (cashbackResult != null && cashbackResult['cashback_amount'] != null) {
          final cashbackAmount = cashbackResult['cashback_amount'];
          PushService.sendPush(
            userId: buyerId,
            title: '🎉 Cashback Earned!',
            body: 'You earned \u20A6${cashbackAmount.toStringAsFixed(0)} cashback from your purchase!',
            data: {'type': 'cashback', 'orderId': orderId},
          );
        }
      } catch (e) {
        print('[OrderCubit] cashback error: $e');
      }

      final orderData2 = await SupabaseService.client
          .from('orders').select('vendor_id').eq('id', orderId).maybeSingle();
      if (orderData2 != null) {
        PushService.sendPush(
          userId: orderData2['vendor_id'] as String,
          title: 'Delivery Confirmed',
          body: 'Buyer confirmed delivery for order #$orderId',
          data: {'type': 'order', 'orderId': orderId},
        );

        await NotificationCubit.create(
          userId: orderData2['vendor_id'] as String,
          title: 'Delivery Confirmed',
          body: 'Buyer confirmed delivery — payment released',
          type: 'vendor_order',
          referenceId: orderId,
        );
      }

      await loadBuyerOrders(buyerId);
      emit(state.copyWith(isSubmitting: false));
      return true;
    } catch (e) {
      print('[OrderCubit] confirmDelivery error: $e');
      emit(state.copyWith(isSubmitting: false));
      return false;
    }
  }

  /// Buyer requests refund — cancels auto-release, starts dispute
  Future<void> requestRefund(String orderId) async {
    try {
      final orderData = await SupabaseService.client
          .from('orders')
          .select('id, vendor_id, buyer_id')
          .eq('id', orderId)
          .maybeSingle();

      if (orderData == null) return;

      _escrow.cancelAutoRelease(orderId);

      await SupabaseService.client.from('orders').update({
        'status': 'refund_requested',
      }).eq('id', orderId);

      PushService.sendPush(
        userId: orderData['vendor_id'] as String,
        title: 'Refund Requested',
        body: 'Buyer requested a refund for order #$orderId',
        data: {'type': 'order', 'orderId': orderId},
      );

      await NotificationCubit.create(
        userId: orderData['vendor_id'] as String,
        title: 'Refund Requested',
        body: 'Buyer requested a refund for order #$orderId — review and respond',
        type: 'vendor_order',
        referenceId: orderId,
      );

      await NotificationCubit.create(
        userId: orderData['buyer_id'] as String,
        title: 'Refund Requested',
        body: 'Your refund request for order #$orderId has been submitted',
        type: 'order',
        referenceId: orderId,
      );

      await loadBuyerOrders(orderData['buyer_id'] as String);
    } catch (e) {
      print('[OrderCubit] requestRefund error: $e');
    }
  }

  /// Buyer-initiated cancellation. Returns null on success, or an error message
  /// to show the buyer. Only allowed BEFORE a rider is booked — once the vendor
  /// has requested a rider the courier fee is committed, so the buyer waits for
  /// delivery or reports a problem instead.
  ///
  /// This no longer refunds directly. It SUBMITS A REFUND REQUEST that an
  /// administrator approves, and an approved refund is paid out to the buyer's
  /// verified bank account. A verified account is therefore required up front —
  /// `no_bank_account` comes back when one is missing so the caller can send the
  /// buyer to add theirs.
  Future<String?> cancelOrder(String orderId, String buyerId) async {
    try {
      final orderData = await SupabaseService.client
          .from('orders')
          .select('id, status, vendor_id, has_shipbubble_delivery')
          .eq('id', orderId)
          .maybeSingle();

      if (orderData == null) return 'Order not found.';
      final status = orderData['status'] as String;
      if (status != 'paid') return 'This order can no longer be cancelled.';
      if (orderData['has_shipbubble_delivery'] as bool? ?? false) {
        return 'A rider has already been booked, so this order can no longer be cancelled.';
      }

      final session = SupabaseService.client.auth.currentSession;
      try {
        await SupabaseService.client.functions.invoke(
          'request-refund',
          headers: {
            'Content-Type': 'application/json',
            if (session != null) 'Authorization': 'Bearer ${session.accessToken}',
          },
          body: {
            'order_id': orderId,
            'reason': 'Buyer cancelled the order',
          },
        );
      } on FunctionException catch (e) {
        // invoke() THROWS on any non-2xx rather than returning it, so a status
        // check here would never run. Reading the body off the exception is the
        // only way to see why the server refused; without this every refusal,
        // including the one we built an "add your bank account" prompt for,
        // arrived as a bare "please try again".
        final data = e.details is Map ? e.details as Map : const {};
        if (data['error'] == 'no_bank_account') return kNoBankAccountError;
        final msg = data['message'] as String? ?? data['error'] as String?;
        return msg ?? 'Could not submit your refund request. Please try again.';
      }

      final vendorId = orderData['vendor_id'] as String;
      PushService.sendPush(
        userId: vendorId,
        title: 'Order Cancelled',
        body: 'A buyer cancelled their order (refund pending review).',
        data: {'type': 'order', 'orderId': orderId},
      );

      await NotificationCubit.create(
        userId: vendorId,
        title: 'Order Cancelled',
        body: 'A buyer cancelled their order (refund pending review).',
        type: 'vendor_order',
        referenceId: orderId,
      );

      // Refunds are reviewed before any money moves and are paid to the buyer's
      // bank, so do not tell them it is already back. The old copy promised an
      // instant credit to a wallet that no longer exists.
      await NotificationCubit.create(
        userId: buyerId,
        title: 'Refund requested',
        body: 'We received your cancellation. Your refund is being reviewed and '
            'will be paid to your bank account.',
        type: 'order',
        referenceId: orderId,
      );

      await loadBuyerOrders(buyerId);
      return null;
    } catch (e) {
      print('[OrderCubit] cancelOrder error: $e');
      return 'Could not cancel the order. Please try again.';
    }
  }

  /// Re-schedule auto-release timers for shipped orders (survives app restart)
  void _rescheduleAutoReleaseTimers(List<Order> orders) {
    for (final order in orders) {
      if (order.status == 'shipped' && order.autoReleaseAt != null) {
        final deadline = order.autoReleaseAt!;
        if (deadline.isAfter(DateTime.now())) {
          _escrow.scheduleAutoRelease(
            orderId: order.id,
            deadline: deadline,
            onRelease: () => _autoRelease(order.id),
          );
        } else {
          _autoRelease(order.id);
        }
      }
    }
  }

  /// At the 24h window's end, a still-silent buyer doesn't get an instant
  /// vendor payout — this just flags the order for admin review and starts
  /// a 12h grace period (extended_release_at). The actual release after that
  /// grace period is handled server-side by the auto-release-escrow cron, so
  /// it still fires even if no one has the app open. A buyer who explicitly
  /// disputed non-delivery is skipped here (has_dispute already true) since
  /// the normal dispute flow already blocks release until resolved.
  Future<void> _autoRelease(String orderId) async {
    try {
      final orderData = await SupabaseService.client
          .from('orders')
          .select('id, status, has_dispute')
          .eq('id', orderId)
          .maybeSingle();

      if (orderData == null) return;
      final status = orderData['status'] as String;
      if (status != 'shipped') return;
      if (orderData['has_dispute'] == true) return;

      final extendedReleaseAt = DateTime.now().add(const Duration(hours: 12));

      // .eq('status', 'shipped') guards against racing the server cron,
      // which does the same flag-flip atomically — a double-fire becomes a
      // harmless no-op.
      await SupabaseService.client
          .from('orders')
          .update({
            'admin_review_flagged': true,
            'admin_review_flagged_at': DateTime.now().toIso8601String(),
            'extended_release_at': extendedReleaseAt.toIso8601String(),
          })
          .eq('id', orderId)
          .eq('status', 'shipped')
          .eq('admin_review_flagged', false);
    } catch (e) {
      print('[OrderCubit] _autoRelease error: $e');
    }
  }

  Stream<Duration> watchTimer(String orderId) {
    return _escrow.watchTimer(orderId).map((deadline) {
      return _escrow.getRemainingTime(deadline);
    });
  }

  String formatTime(Duration d) => _escrow.formatRemainingTime(d);

  @override
  Future<void> close() {
    _ordersChannel?.unsubscribe();
    _escrow.dispose();
    return super.close();
  }
}

class OrderState {
  final bool isLoading;
  final bool isSubmitting;
  final List<Order> buyerOrders;
  final List<Order> vendorOrders;

  OrderState({
    this.isLoading = false,
    this.isSubmitting = false,
    this.buyerOrders = const [],
    this.vendorOrders = const [],
  });

  OrderState copyWith({
    bool? isLoading,
    bool? isSubmitting,
    List<Order>? buyerOrders,
    List<Order>? vendorOrders,
  }) {
    return OrderState(
      isLoading: isLoading ?? this.isLoading,
      isSubmitting: isSubmitting ?? this.isSubmitting,
      buyerOrders: buyerOrders ?? this.buyerOrders,
      vendorOrders: vendorOrders ?? this.vendorOrders,
    );
  }
}
