import 'dart:convert';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:uuid/uuid.dart';
import '../services/supabase_service.dart';
import '../services/push_service.dart';
import '../services/storage_service.dart';
import '../services/payment_service.dart';
import '../models/models.dart';
import 'notification_bloc.dart';

class DisputeCubit extends Cubit<DisputeState> {
  DisputeCubit() : super(DisputeState());

  final _uuid = const Uuid();

  // Select all columns rather than hand-listing them: the previous explicit list
  // requested `vendor_response`, which doesn't exist in the table, so the WHOLE
  // query errored and returned an empty disputes list (buyer AND vendor). The
  // Dispute model already null-safes any missing field, so `*` is safe + robust
  // against future schema drift.
  static const _disputeFields = '*';

  // Parse rows one at a time so a single malformed dispute can't wipe the whole
  // list (which previously hid every dispute from the vendor/buyer).
  List<Dispute> _parseDisputes(List rows) {
    final out = <Dispute>[];
    for (final d in rows) {
      try {
        out.add(Dispute.fromJson(d as Map<String, dynamic>));
      } catch (e) {
        print('[DisputeCubit] skipped unparseable dispute: $e');
      }
    }
    return out;
  }

  Future<void> loadDisputesForVendor(String vendorId) async {
    emit(state.copyWith(isLoading: true));
    try {
      final disputesData = await SupabaseService.client
          .from('disputes')
          .select(_disputeFields)
          .eq('vendor_id', vendorId)
          .order('created_at', ascending: false)
          .limit(100);

      final disputes = _parseDisputes(disputesData as List);
      emit(state.copyWith(isLoading: false, vendorDisputes: disputes));
    } catch (e) {
      print('[DisputeCubit] loadDisputesForVendor error: $e');
      emit(state.copyWith(isLoading: false));
    }
  }

  Future<void> loadDisputesForBuyer(String buyerId) async {
    emit(state.copyWith(isLoading: true));
    try {
      final disputesData = await SupabaseService.client
          .from('disputes')
          .select(_disputeFields)
          .eq('buyer_id', buyerId)
          .order('created_at', ascending: false)
          .limit(100);

      final disputes = _parseDisputes(disputesData as List);
      emit(state.copyWith(isLoading: false, buyerDisputes: disputes));
    } catch (e) {
      print('[DisputeCubit] loadDisputesForBuyer error: $e');
      emit(state.copyWith(isLoading: false));
    }
  }

  Future<void> loadDisputeById(String disputeId) async {
    emit(state.copyWith(isLoading: true));
    try {
      final data = await SupabaseService.client
          .from('disputes')
          .select(_disputeFields)
          .eq('id', disputeId)
          .maybeSingle();

      if (data != null) {
        final dispute = Dispute.fromJson(data);
        emit(state.copyWith(isLoading: false, currentDispute: dispute));
      } else {
        emit(state.copyWith(isLoading: false));
      }
    } catch (e) {
      print('[DisputeCubit] loadDisputeById error: $e');
      emit(state.copyWith(isLoading: false));
    }
  }

  /// Valid dispute reasons under the strict policy — exactly 4, no "other".
  static const validIssueTypes = ['wrong_item', 'damaged', 'not_as_described', 'not_received'];

  /// Runs the pre-validation checks required before a buyer may open a
  /// dispute. Pass [issueType] when known (e.g. at submit time) so
  /// "not_received" can bypass the closed-window check — a buyer who never
  /// got their package shouldn't lose the right to report that just because
  /// the auto-release clock ran out; everyone else's window is final once
  /// it closes (confirming or auto-releasing is a deliberate, one-time act).
  Future<DisputeEligibility> checkDisputeEligibility({
    required String orderId,
    required String buyerId,
    required String vendorId,
    String? issueType,
  }) async {
    try {
      final order = await SupabaseService.client
          .from('orders')
          .select('id, auto_release_at, has_dispute, status')
          .eq('id', orderId)
          .maybeSingle();
      if (order == null) return DisputeEligibility.blocked('Order not found.');
      if (order['has_dispute'] == true) {
        return DisputeEligibility.blocked('This order already has an active dispute.');
      }

      final status = order['status'] as String?;

      // Explicit confirmation is a deliberate "this is correct" act — never
      // disputable afterward, not even for "not_received" (contradictory).
      if (status == 'confirmed') {
        return DisputeEligibility.blocked('You already confirmed you received this order — it can no longer be disputed.');
      }
      if (status == 'paid') {
        return DisputeEligibility.blocked('Your order hasn\'t shipped yet — the window to report a problem opens once it ships.');
      }
      if (status != 'shipped' && status != 'auto_released') {
        return DisputeEligibility.blocked('This order has already been closed — it can no longer be disputed.');
      }

      // There is one 24h (or longer, for courier) inspection window, opened
      // when the vendor ships (auto_release_at). For every reason EXCEPT
      // "not_received", the buyer must confirm or dispute within it — once
      // it closes (status flips to 'auto_released'), that's final. See
      // order_bloc.dart confirmDelivery()/markShipped().
      final deadline = order['auto_release_at'] != null ? DateTime.parse(order['auto_release_at']) : null;
      final windowOpen = status == 'shipped' && deadline != null && DateTime.now().isBefore(deadline);

      if (!windowOpen) {
        if (issueType == 'not_received') {
          // Bypass: the buyer never got anything to inspect or confirm —
          // there's no reason this claim should expire with the timer.
        } else if (issueType == null) {
          return DisputeEligibility.windowClosedButNotReceivedAllowed(
            'The 24-hour window has closed for general issues — you can still report "Item not received".',
          );
        } else {
          return DisputeEligibility.blocked('The 24-hour window to report a problem has closed.');
        }
      }

      final user = await SupabaseService.client
          .from('users')
          .select('dispute_flagged, active_dispute_id, last_dispute_at, last_dispute_vendor_id')
          .eq('id', buyerId)
          .maybeSingle();
      if (user == null) return DisputeEligibility.blocked('Account not found.');
      if (user['dispute_flagged'] == true) {
        return DisputeEligibility.blocked('Your account is flagged for repeated disputes and cannot open new ones. Contact support.');
      }
      if (user['active_dispute_id'] != null) {
        return DisputeEligibility.blocked('You already have an active dispute in progress.');
      }

      if (user['last_dispute_vendor_id'] == vendorId && user['last_dispute_at'] != null) {
        final last = DateTime.parse(user['last_dispute_at']);
        final cooldownEnds = last.add(const Duration(days: 30));
        if (DateTime.now().isBefore(cooldownEnds)) {
          return DisputeEligibility.blocked(
            'You opened a dispute with this vendor recently. Please wait until ${cooldownEnds.toLocal().toString().split(' ').first} before disputing this vendor again.',
          );
        }
      }

      return DisputeEligibility.ok();
    } catch (e) {
      print('[DisputeCubit] checkDisputeEligibility error: $e');
      return DisputeEligibility.blocked('Could not verify dispute eligibility. Try again.');
    }
  }

  /// Create dispute with camera-only photo evidence and a fixed issue type.
  /// Caller must run [checkDisputeEligibility] first and block submission on
  /// a non-null result — this method does not re-check eligibility itself.
  Future<bool> createDispute({
    required String orderId,
    required String buyerId,
    required String vendorId,
    required String reason,
    required String issueType,
    required String buyerPhone,
    required String deliveryAddress,
    String? explanation,
    List<String>? evidencePaths, // local file paths, camera-only, 2-5 photos
    String? videoPath, // required when order total > 50,000
  }) async {
    if (!validIssueTypes.contains(issueType)) {
      print('[DisputeCubit] createDispute rejected: invalid issueType $issueType');
      return false;
    }
    emit(state.copyWith(isSubmitting: true));
    try {
      List<String> evidenceUrls = [];
      final tempId = 'temp_${_uuid.v4()}';

      if (evidencePaths != null && evidencePaths.isNotEmpty) {
        for (final path in evidencePaths) {
          try {
            final url = await StorageService.uploadDisputeEvidence(
              disputeId: tempId,
              filePath: path,
            );
            if (url != null) evidenceUrls.add(url);
          } catch (e) {
            print('[DisputeCubit] Upload evidence error: $e');
          }
        }
      }

      String? videoUrl;
      if (videoPath != null) {
        try {
          videoUrl = await StorageService.uploadDisputeEvidence(
            disputeId: tempId,
            filePath: videoPath,
          );
        } catch (e) {
          print('[DisputeCubit] Upload video error: $e');
        }
      }

      final now = DateTime.now();
      final vendorResponseDeadline = now.add(const Duration(hours: 24));

      final inserted = await SupabaseService.client.from('disputes').insert({
        'order_id': orderId,
        'buyer_id': buyerId,
        'vendor_id': vendorId,
        'raised_by': buyerId,
        'reason': reason,
        'buyer_explanation': explanation,
        'buyer_phone': buyerPhone,
        'delivery_address': deliveryAddress,
        'issue_type': issueType,
        'evidence_urls': jsonEncode(evidenceUrls),
        'video_url': videoUrl,
        'status': 'awaiting_vendor_response',
        'resolution_deadline': vendorResponseDeadline.toIso8601String(),
        'vendor_response_deadline': vendorResponseDeadline.toIso8601String(),
        'buyer_submitted_at': now.toIso8601String(),
      }).select('id').single();

      final disputeId = inserted['id'] as String;

      await SupabaseService.client.from('orders').update({
        'has_dispute': true,
      }).eq('id', orderId);

      // Set via a SECURITY DEFINER RPC — these anti-gaming fields are guarded
      // against direct client writes (a buyer can't clear active_dispute_id to
      // open multiple disputes or reset the per-vendor cooldown).
      await SupabaseService.client.rpc('claim_active_dispute', params: {
        'p_dispute_id': disputeId,
        'p_vendor_id': vendorId,
      });

      // If escrow already paid the vendor out for this order, hold their NEXT
      // payout for the order amount so a buyer-favour refund is funded from the
      // held vendor money rather than the platform's own pocket. This MUST run
      // server-side: users.payout_blocked is guarded against client writes, so
      // the old client-side update silently failed and the hold never applied.
      // The RPC verifies the caller is the order's buyer, checks payment_released,
      // and sets the dispute + hold atomically (idempotent).
      try {
        await SupabaseService.client.rpc('apply_dispute_payout_hold', params: {
          'p_dispute_id': disputeId,
          'p_order_id': orderId,
        });
      } catch (e) {
        print('[DisputeCubit] apply_dispute_payout_hold error: $e');
      }

      PushService.sendPush(
        userId: vendorId,
        title: 'Dispute Opened',
        body: 'A buyer opened a dispute. You must respond within 24 hours.',
        data: {'type': 'dispute', 'orderId': orderId},
      );

      await NotificationCubit.create(
        userId: vendorId,
        title: 'Dispute Opened',
        body: 'A buyer opened a dispute for order #$orderId — respond within 24 hours or it auto-escalates to admin',
        type: 'dispute',
        referenceId: orderId,
      );

      emit(state.copyWith(isSubmitting: false));
      return true;
    } catch (e) {
      print('[DisputeCubit] createDispute error: $e');
      emit(state.copyWith(isSubmitting: false));
      return false;
    }
  }

  /// Vendor responds with text
  Future<void> vendorRespond(String disputeId, String response) async {
    try {
      await SupabaseService.client.from('disputes').update({
        'vendor_response': response,
        'status': 'vendor_responded',
        'vendor_responded_at': DateTime.now().toIso8601String(),
      }).eq('id', disputeId);

      final disputeData = await SupabaseService.client
          .from('disputes').select('buyer_id').eq('id', disputeId).maybeSingle();
      if (disputeData != null) {
        PushService.sendPush(
          userId: disputeData['buyer_id'] as String,
          title: 'Vendor Responded',
          body: response,
          data: {'type': 'dispute', 'orderId': disputeId},
        );

        await NotificationCubit.create(
          userId: disputeData['buyer_id'] as String,
          title: 'Vendor Responded',
          body: response.length > 100 ? '${response.substring(0, 100)}...' : response,
          type: 'dispute',
          referenceId: disputeId,
        );
      }

      // Reload current dispute
      await loadDisputeById(disputeId);
    } catch (e) {
      print('[DisputeCubit] vendorRespond error: $e');
    }
  }

  /// Vendor uploads counter-evidence
  Future<void> vendorUploadEvidence(String disputeId, List<String> evidencePaths) async {
    emit(state.copyWith(isSubmitting: true));
    try {
      List<String> existingUrls = [];
      final disputeData = await SupabaseService.client
          .from('disputes')
          .select('vendor_evidence_urls')
          .eq('id', disputeId)
          .maybeSingle();

      if (disputeData != null && disputeData['vendor_evidence_urls'] != null) {
        try {
          final decoded = jsonDecode(disputeData['vendor_evidence_urls'] as String);
          if (decoded is List) existingUrls = decoded.cast<String>();
        } catch (_) {}
      }

      List<String> newUrls = [];
      for (final path in evidencePaths) {
        try {
          final url = await StorageService.uploadDisputeEvidence(
            disputeId: disputeId,
            filePath: path,
          );
          if (url != null) newUrls.add(url);
        } catch (e) {
          print('[DisputeCubit] Upload vendor evidence error: $e');
        }
      }

      final allUrls = [...existingUrls, ...newUrls];
      await SupabaseService.client.from('disputes').update({
        'vendor_evidence_urls': jsonEncode(allUrls),
        'status': 'evidence_submitted',
        'vendor_responded_at': DateTime.now().toIso8601String(),
      }).eq('id', disputeId);

      emit(state.copyWith(isSubmitting: false));
      await loadDisputeById(disputeId);
    } catch (e) {
      print('[DisputeCubit] vendorUploadEvidence error: $e');
      emit(state.copyWith(isSubmitting: false));
    }
  }

  /// Vendor offers replacement product
  Future<void> offerReplacement(String disputeId, String productId) async {
    try {
      await SupabaseService.client.from('disputes').update({
        'replacement_product_id': productId,
        'resolution_type': 'replacement',
        'status': 'replacement_offered',
      }).eq('id', disputeId);

      final disputeData = await SupabaseService.client
          .from('disputes').select('buyer_id').eq('id', disputeId).maybeSingle();
      if (disputeData != null) {
        PushService.sendPush(
          userId: disputeData['buyer_id'] as String,
          title: 'Replacement Offered',
          body: 'The vendor offered a replacement product. Review and accept or reject.',
          data: {'type': 'dispute', 'orderId': disputeId},
        );
      }

      await loadDisputeById(disputeId);
    } catch (e) {
      print('[DisputeCubit] offerReplacement error: $e');
    }
  }

  /// Buyer accepts replacement. Runs server-side: the original payment stays in
  /// escrow and the order resets to "paid" so the vendor ships the replacement
  /// (a client can't clear the guarded active-dispute lock or reset protected
  /// order fields, and leaving has_dispute set would strand the money in escrow).
  Future<void> acceptReplacement(String disputeId) async {
    try {
      final res = await SupabaseService.client.functions.invoke(
        'accept-replacement',
        body: {'dispute_id': disputeId},
      );
      final data = res.data;
      if (data is Map && data['error'] != null) {
        print('[DisputeCubit] acceptReplacement server error: ${data['error']}');
      }
      await loadDisputeById(disputeId);
    } catch (e) {
      print('[DisputeCubit] acceptReplacement error: $e');
    }
  }

  /// Buyer rejects replacement → back to the vendor's negotiation options
  /// (offer another, accept the refund, or send to admin). The dispute stays
  /// open (money still held) — we do NOT drop it to a dead 'open' state.
  Future<void> rejectReplacement(String disputeId) async {
    try {
      await SupabaseService.client.from('disputes').update({
        'replacement_product_id': null,
        'resolution_type': null,
        'status': 'awaiting_vendor_response',
        'vendor_response_deadline':
            DateTime.now().add(const Duration(hours: 24)).toIso8601String(),
      }).eq('id', disputeId);

      final disputeData = await SupabaseService.client
          .from('disputes').select('vendor_id, order_id').eq('id', disputeId).maybeSingle();
      if (disputeData != null && disputeData['vendor_id'] != null) {
        PushService.sendPush(
          userId: disputeData['vendor_id'] as String,
          title: 'Replacement declined',
          body: 'The buyer declined your replacement. Offer another, accept the refund, or send it to admin.',
          data: {'type': 'dispute', 'orderId': disputeData['order_id']},
        );
      }
      await loadDisputeById(disputeId);
    } catch (e) {
      print('[DisputeCubit] rejectReplacement error: $e');
    }
  }

  /// Vendor accepts refund — dispute/order are only marked resolved once the
  /// process-refund Edge Function confirms the money has actually moved.
  /// Never write status='resolved'/'refunded' locally on failure — that
  /// would record a refund that never happened (common on flaky networks).
  Future<bool> acceptRefund(String disputeId) async {
    // Runs through the vendor-accept-refund Edge Function: it authenticates the
    // vendor and processes the refund under the service role (calling
    // process-refund directly from here 403s — vendors aren't allowed refund
    // callers). The function also claws back the vendor + releases the hold and
    // notifies the buyer, so there's nothing more to do here.
    try {
      final result = await PaymentService.vendorAcceptRefund(disputeId: disputeId);
      if (result['error'] != null) {
        print('[DisputeCubit] acceptRefund server error: ${result['error']}');
        return false;
      }
      await loadDisputeById(disputeId);
      return true;
    } catch (e) {
      print('[DisputeCubit] acceptRefund error: $e');
      return false;
    }
  }

  /// Vendor rejects refund with reason
  Future<void> rejectRefund(String disputeId, String reason) async {
    try {
      await SupabaseService.client.from('disputes').update({
        'status': 'rejected',
        'resolution_type': 'rejected',
        'vendor_response': reason,
      }).eq('id', disputeId);

      final disputeData = await SupabaseService.client
          .from('disputes').select('buyer_id').eq('id', disputeId).maybeSingle();
      if (disputeData != null && disputeData['buyer_id'] != null) {
        PushService.sendPush(
          userId: disputeData['buyer_id'] as String,
          title: 'Refund Rejected',
          body: 'Your refund request was rejected. Reason: $reason',
          data: {'type': 'dispute', 'orderId': disputeId},
        );
      }

      await loadDisputeById(disputeId);
    } catch (e) {
      print('[DisputeCubit] rejectRefund error: $e');
    }
  }

  /// Buyer cancels dispute and confirms delivery instead
  Future<bool> cancelDisputeAndConfirm({
    required String disputeId,
    required String orderId,
    required String buyerId,
    required String deliveryPhotoPath,
  }) async {
    emit(state.copyWith(isSubmitting: true));
    try {
      final deliveryPhotoUrl = await StorageService.uploadDeliveryConfirmation(
        orderId: orderId,
        filePath: deliveryPhotoPath,
      );

      if (deliveryPhotoUrl == null) {
        emit(state.copyWith(isSubmitting: false));
        return false;
      }

      await SupabaseService.client.from('disputes').update({
        'status': 'cancelled',
        'resolved_at': DateTime.now().toIso8601String(),
      }).eq('id', disputeId);

      // Intentionally does NOT write any dispute-window field — confirming
      // closes the inspection window, it never opens a new one. Don't "fix"
      // this by copying the old confirmDelivery() pattern.
      await SupabaseService.client.from('orders').update({
        'status': 'confirmed',
        'confirmed_at': DateTime.now().toIso8601String(),
        'delivery_photo_url': deliveryPhotoUrl,
        'delivery_confirmed_at': DateTime.now().toIso8601String(),
      }).eq('id', orderId);

      emit(state.copyWith(isSubmitting: false));
      return true;
    } catch (e) {
      print('[DisputeCubit] cancelDisputeAndConfirm error: $e');
      emit(state.copyWith(isSubmitting: false));
      return false;
    }
  }

  /// Escalate dispute to admin
  Future<void> escalateToAdmin(String disputeId) async {
    try {
      await SupabaseService.client.from('disputes').update({
        'escalated_to_admin': true,
        'status': 'escalated',
      }).eq('id', disputeId);

      final disputeData = await SupabaseService.client
          .from('disputes').select('buyer_id, vendor_id').eq('id', disputeId).maybeSingle();
      if (disputeData != null) {
        PushService.sendPush(
          userId: disputeData['buyer_id'] as String,
          title: 'Dispute Escalated',
          body: 'Your dispute has been escalated to platform admin.',
          data: {'type': 'dispute', 'orderId': disputeId},
        );
      }

      await loadDisputeById(disputeId);
    } catch (e) {
      print('[DisputeCubit] escalateToAdmin error: $e');
    }
  }

  /// Check for auto-escalation (called periodically). Server-side
  /// auto-close-disputes Edge Function (pg_cron) is the source of truth;
  /// this is a client-side best-effort nudge for when the app is open.
  Future<void> checkAutoEscalation() async {
    try {
      final now = DateTime.now().toIso8601String();
      await SupabaseService.client.from('disputes').update({
        'escalated_to_admin': true,
        'status': 'escalated',
      }).lt('vendor_response_deadline', now)
        .eq('status', 'awaiting_vendor_response');
    } catch (e) {
      print('[DisputeCubit] checkAutoEscalation error: $e');
    }
  }

  /// Vendor responds within the 24h window — moves dispute to admin review
  /// rather than resolving it directly (admin makes the final call).
  Future<void> vendorRespondStrict(String disputeId, String response, {List<String>? evidencePaths}) async {
    try {
      List<String> urls = [];
      if (evidencePaths != null) {
        for (final path in evidencePaths) {
          final url = await StorageService.uploadDisputeEvidence(disputeId: disputeId, filePath: path);
          if (url != null) urls.add(url);
        }
      }
      await SupabaseService.client.from('disputes').update({
        'vendor_response': response,
        'vendor_evidence_urls': jsonEncode(urls),
        'status': 'awaiting_admin_decision',
        'vendor_responded_at': DateTime.now().toIso8601String(),
      }).eq('id', disputeId);

      await loadDisputeById(disputeId);
    } catch (e) {
      print('[DisputeCubit] vendorRespondStrict error: $e');
    }
  }

  /// Admin approves the refund. If [requireReturn] is true the buyer must
  /// ship the item back within 24 hours and the vendor must confirm receipt
  /// before the refund is actually processed; otherwise the refund proceeds
  /// immediately.
  Future<bool> adminApproveRefund({
    required String disputeId,
    required String adminId,
    String? notes,
    bool requireReturn = true,
    String refundMethod = 'credit',
  }) async {
    try {
      final dispute = await SupabaseService.client
          .from('disputes').select('order_id, buyer_id, vendor_id').eq('id', disputeId).maybeSingle();
      if (dispute == null) return false;

      if (requireReturn) {
        final returnDeadline = DateTime.now().add(const Duration(hours: 24));
        await SupabaseService.client.from('disputes').update({
          'admin_decision': 'refund_approved',
          'admin_decided_by': adminId,
          'admin_decided_at': DateTime.now().toIso8601String(),
          'admin_notes': notes,
          'return_required': true,
          'return_deadline': returnDeadline.toIso8601String(),
          'refund_method': refundMethod,
          'status': 'awaiting_return',
        }).eq('id', disputeId);

        PushService.sendPush(
          userId: dispute['buyer_id'] as String,
          title: 'Refund Approved — Return Required',
          body: 'Admin approved your refund. Return the item within 24 hours to receive payment.',
          data: {'type': 'dispute', 'orderId': dispute['order_id']},
        );
      } else {
        await SupabaseService.client.from('disputes').update({
          'admin_decision': 'refund_approved',
          'admin_decided_by': adminId,
          'admin_decided_at': DateTime.now().toIso8601String(),
          'admin_notes': notes,
          'return_required': false,
          'refund_method': refundMethod,
          'status': 'resolved',
          'resolution_type': 'refund',
          'resolved_at': DateTime.now().toIso8601String(),
        }).eq('id', disputeId);

        await PaymentService.processRefund(
          orderId: dispute['order_id'],
          disputeId: disputeId,
          reason: 'Dispute resolved by admin in buyer\'s favor',
          refundMethod: refundMethod,
        );
        // process-refund releases the vendor payout hold (atomic + idempotent).
      }

      await SupabaseService.client.from('users').update({
        'active_dispute_id': null,
      }).eq('id', dispute['buyer_id']);

      await loadDisputeById(disputeId);
      return true;
    } catch (e) {
      print('[DisputeCubit] adminApproveRefund error: $e');
      return false;
    }
  }

  /// Admin denies the refund. Buyer gets a strike; 3 strikes flags the
  /// account from opening further disputes. Any held vendor payout for this
  /// dispute is released back to the vendor in full.
  Future<bool> adminDenyRefund({
    required String disputeId,
    required String adminId,
    required String notes,
  }) async {
    try {
      final dispute = await SupabaseService.client
          .from('disputes').select('order_id, buyer_id, vendor_id').eq('id', disputeId).maybeSingle();
      if (dispute == null) return false;

      await SupabaseService.client.from('disputes').update({
        'admin_decision': 'refund_denied',
        'admin_decided_by': adminId,
        'admin_decided_at': DateTime.now().toIso8601String(),
        'admin_notes': notes,
        'status': 'denied',
        'resolution_type': 'rejected',
        'resolved_at': DateTime.now().toIso8601String(),
      }).eq('id', disputeId);

      await _addStrike(dispute['buyer_id'] as String);

      await SupabaseService.client.from('users').update({
        'active_dispute_id': null,
      }).eq('id', dispute['buyer_id']);

      await SupabaseService.client.from('orders').update({
        'has_dispute': false,
      }).eq('id', dispute['order_id']);

      await _releaseVendorPayoutHold(dispute['vendor_id'] as String, disputeId);

      PushService.sendPush(
        userId: dispute['buyer_id'] as String,
        title: 'Dispute Denied',
        body: 'Admin reviewed your dispute and denied the refund. Reason: $notes',
        data: {'type': 'dispute', 'orderId': dispute['order_id']},
      );

      await loadDisputeById(disputeId);
      return true;
    } catch (e) {
      print('[DisputeCubit] adminDenyRefund error: $e');
      return false;
    }
  }

  /// Releases the vendor's held payout for [disputeId] back to them — call
  /// this whenever a dispute resolves WITHOUT a refund actually being paid
  /// out of the held amount (denial, or no-return-required approval that's
  /// funded straight from the platform).
  Future<void> _releaseVendorPayoutHold(String vendorId, String disputeId) async {
    // Server-side + atomic + idempotent. users.payout_blocked is guarded against
    // client writes, so this can only work from an admin/service context — the
    // RPC enforces that. Only used by the admin-deny path now; the refund paths
    // release the hold inside process-refund itself.
    try {
      await SupabaseService.client.rpc('release_dispute_payout_hold', params: {
        'p_dispute_id': disputeId,
      });
    } catch (e) {
      print('[DisputeCubit] _releaseVendorPayoutHold error: $e');
    }
  }

  Future<void> _addStrike(String buyerId) async {
    try {
      final user = await SupabaseService.client
          .from('users').select('dispute_strikes_count').eq('id', buyerId).maybeSingle();
      final count = ((user?['dispute_strikes_count'] as int?) ?? 0) + 1;
      final flagged = count >= 3;
      await SupabaseService.client.from('users').update({
        'dispute_strikes_count': count,
        if (flagged) 'dispute_flagged': true,
        if (flagged) 'dispute_flagged_at': DateTime.now().toIso8601String(),
      }).eq('id', buyerId);
    } catch (e) {
      print('[DisputeCubit] _addStrike error: $e');
    }
  }

  /// Buyer uploads two camera photos (packaged item + handover to rider)
  /// after admin approves a refund requiring a return. No courier name or
  /// tracking number is collected — the vendor confirms receipt directly.
  Future<bool> submitReturn({
    required String disputeId,
    required String packagePhotoPath,
    required String handoverPhotoPath,
  }) async {
    emit(state.copyWith(isSubmitting: true));
    try {
      final packageUrl = await StorageService.uploadDisputeEvidence(disputeId: disputeId, filePath: packagePhotoPath);
      final handoverUrl = await StorageService.uploadDisputeEvidence(disputeId: disputeId, filePath: handoverPhotoPath);

      await SupabaseService.client.from('disputes').update({
        'return_receipt_photos': jsonEncode([packageUrl, handoverUrl]),
        'return_uploaded_at': DateTime.now().toIso8601String(),
        'status': 'return_submitted',
      }).eq('id', disputeId);

      emit(state.copyWith(isSubmitting: false));
      await loadDisputeById(disputeId);
      return true;
    } catch (e) {
      print('[DisputeCubit] submitReturn error: $e');
      emit(state.copyWith(isSubmitting: false));
      return false;
    }
  }

  /// Admin reviews the buyer's return photos and, if they look legitimate,
  /// hands off to the vendor for final confirmation rather than refunding
  /// immediately — the vendor has 24 hours to confirm or dispute receipt.
  Future<bool> adminVerifyReturn({required String disputeId, required String adminId}) async {
    try {
      final dispute = await SupabaseService.client
          .from('disputes').select('order_id, vendor_id').eq('id', disputeId).maybeSingle();
      if (dispute == null) return false;

      final confirmDeadline = DateTime.now().add(const Duration(hours: 24));
      await SupabaseService.client.from('disputes').update({
        'return_verified': true,
        'return_verified_at': DateTime.now().toIso8601String(),
        'status': 'vendor_confirming',
        'vendor_confirm_deadline': confirmDeadline.toIso8601String(),
      }).eq('id', disputeId);

      PushService.sendPush(
        userId: dispute['vendor_id'] as String,
        title: 'Confirm Return Receipt',
        body: 'Buyer has returned the item. Please confirm receipt within 24 hours or refund will be processed automatically.',
        data: {'type': 'dispute', 'orderId': dispute['order_id']},
      );

      await loadDisputeById(disputeId);
      return true;
    } catch (e) {
      print('[DisputeCubit] adminVerifyReturn error: $e');
      return false;
    }
  }

  /// Vendor confirms they received the returned item — refund proceeds.
  Future<bool> vendorConfirmReturnReceived({
    required String disputeId,
    required String receivedPhotoPath,
  }) async {
    try {
      // Upload the receipt photo, then let the server finalize everything. This
      // MUST go through vendor-confirm-return: calling process-refund from here
      // fails (a vendor isn't an allowed refund caller — it 403s), which used to
      // leave the return "resolved" with no refund actually paid. The Edge
      // Function authenticates the vendor, then runs the refund + clawback +
      // payout-hold release under the service role.
      final photoUrl = await StorageService.uploadDisputeEvidence(disputeId: disputeId, filePath: receivedPhotoPath);

      final result = await PaymentService.vendorConfirmReturn(
        disputeId: disputeId,
        receivedPhotoUrl: photoUrl,
      );
      if (result['error'] != null) {
        print('[DisputeCubit] vendorConfirmReturnReceived server error: ${result['error']}');
        return false;
      }

      await loadDisputeById(disputeId);
      return true;
    } catch (e) {
      print('[DisputeCubit] vendorConfirmReturnReceived error: $e');
      return false;
    }
  }

  /// Vendor disputes that they received the return — sends it back to admin
  /// for a final decision rather than auto-refunding.
  Future<bool> vendorDisputeReturn({
    required String disputeId,
    required String notReceivedPhotoPath,
  }) async {
    try {
      final photoUrl = await StorageService.uploadDisputeEvidence(disputeId: disputeId, filePath: notReceivedPhotoPath);

      await SupabaseService.client.from('disputes').update({
        'vendor_return_received_photo': photoUrl,
        'status': 'awaiting_admin_decision',
        'admin_notes': 'Vendor disputes receiving the return. Final admin review required.',
      }).eq('id', disputeId);

      await loadDisputeById(disputeId);
      return true;
    } catch (e) {
      print('[DisputeCubit] vendorDisputeReturn error: $e');
      return false;
    }
  }

  /// All disputes awaiting admin action — for the admin dashboard.
  Future<List<Dispute>> loadDisputesForAdmin() async {
    try {
      final data = await SupabaseService.client
          .from('disputes')
          .select(_disputeFields)
          .inFilter('status', ['awaiting_admin_decision', 'escalated', 'return_submitted'])
          .order('created_at', ascending: true);
      return (data as List).map((d) => Dispute.fromJson(d)).toList();
    } catch (e) {
      print('[DisputeCubit] loadDisputesForAdmin error: $e');
      return [];
    }
  }
}

/// Result of [DisputeCubit.checkDisputeEligibility]. [reason] is a
/// user-facing string whenever [eligible] is false.
class DisputeEligibility {
  final bool eligible;
  final bool windowClosedButNotReceivedAllowed;
  final String? reason;

  const DisputeEligibility._(this.eligible, this.windowClosedButNotReceivedAllowed, this.reason);

  factory DisputeEligibility.ok() => const DisputeEligibility._(true, false, null);
  factory DisputeEligibility.blocked(String reason) => DisputeEligibility._(false, false, reason);
  factory DisputeEligibility.windowClosedButNotReceivedAllowed(String reason) =>
      DisputeEligibility._(false, true, reason);
}

class DisputeState {
  final bool isLoading;
  final bool isSubmitting;
  final List<Dispute> vendorDisputes;
  final List<Dispute> buyerDisputes;
  final Dispute? currentDispute;

  DisputeState({
    this.isLoading = false,
    this.isSubmitting = false,
    this.vendorDisputes = const [],
    this.buyerDisputes = const [],
    this.currentDispute,
  });

  DisputeState copyWith({
    bool? isLoading,
    bool? isSubmitting,
    List<Dispute>? vendorDisputes,
    List<Dispute>? buyerDisputes,
    Dispute? currentDispute,
  }) {
    return DisputeState(
      isLoading: isLoading ?? this.isLoading,
      isSubmitting: isSubmitting ?? this.isSubmitting,
      vendorDisputes: vendorDisputes ?? this.vendorDisputes,
      buyerDisputes: buyerDisputes ?? this.buyerDisputes,
      currentDispute: currentDispute ?? this.currentDispute,
    );
  }
}
