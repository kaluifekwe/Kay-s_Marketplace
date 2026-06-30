


SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;


CREATE SCHEMA IF NOT EXISTS "public";


ALTER SCHEMA "public" OWNER TO "pg_database_owner";


COMMENT ON SCHEMA "public" IS 'standard public schema';



CREATE OR REPLACE FUNCTION "public"."claim_active_dispute"("p_dispute_id" "uuid", "p_vendor_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
BEGIN
  PERFORM set_config('app.allow_credit', '1', true);
  UPDATE users
     SET active_dispute_id = p_dispute_id,
         last_dispute_at = now(),
         last_dispute_vendor_id = p_vendor_id
   WHERE id = auth.uid();
END;
$$;


ALTER FUNCTION "public"."claim_active_dispute"("p_dispute_id" "uuid", "p_vendor_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_chat_list"("p_user_id" "uuid", "p_role" "text") RETURNS TABLE("chat_id" "uuid", "order_id" "text", "buyer_id" "uuid", "vendor_id" "uuid", "created_at" timestamp with time zone, "unread_count" bigint, "last_msg_id" "uuid", "last_msg_content" "text", "last_msg_type" "text", "last_msg_sender_id" "uuid", "last_msg_sender_role" "text", "last_msg_created_at" timestamp with time zone)
    LANGUAGE "sql" SECURITY DEFINER
    AS $$
  WITH user_chats AS (
    SELECT c.id, c.order_id, c.buyer_id, c.vendor_id, c.created_at
    FROM chats c
    WHERE (p_role = 'buyer' AND c.buyer_id = p_user_id)
       OR (p_role = 'vendor' AND c.vendor_id = p_user_id)
  ),
  last_msgs AS (
    SELECT DISTINCT ON (m.chat_id)
      m.chat_id, m.id as last_msg_id, m.content as last_msg_content,
      m.type as last_msg_type, m.sender_id as last_msg_sender_id,
      m.sender_role as last_msg_sender_role, m.created_at as last_msg_created_at
    FROM messages m
    WHERE m.chat_id IN (SELECT id FROM user_chats)
    ORDER BY m.chat_id, m.created_at DESC
  ),
  unread AS (
    SELECT m.chat_id, COUNT(*) as unread_count
    FROM messages m
    WHERE m.chat_id IN (SELECT id FROM user_chats)
      AND m.sender_id != p_user_id
      AND m.read_at IS NULL
    GROUP BY m.chat_id
  )
  SELECT
    uc.id as chat_id, uc.order_id, uc.buyer_id, uc.vendor_id, uc.created_at,
    COALESCE(u.unread_count, 0) as unread_count,
    lm.last_msg_id, lm.last_msg_content, lm.last_msg_type,
    lm.last_msg_sender_id, lm.last_msg_sender_role, lm.last_msg_created_at
  FROM user_chats uc
  LEFT JOIN unread u ON u.chat_id = uc.id
  LEFT JOIN last_msgs lm ON lm.chat_id = uc.id
  ORDER BY u.unread_count DESC NULLS LAST, COALESCE(lm.last_msg_created_at, uc.created_at) DESC;
$$;


ALTER FUNCTION "public"."get_chat_list"("p_user_id" "uuid", "p_role" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_store_review_stats"("p_store_id" "uuid") RETURNS TABLE("avg_rating" numeric, "review_count" bigint)
    LANGUAGE "sql" STABLE
    AS $$
  SELECT COALESCE(AVG(rating), 0), COUNT(*)
  FROM reviews
  WHERE store_id = p_store_id;
$$;


ALTER FUNCTION "public"."get_store_review_stats"("p_store_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."grant_welcome_credit"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
BEGIN
  IF NEW.role = 'buyer' THEN
    PERFORM set_config('app.allow_credit', '1', true);
    UPDATE users SET kays_credit = COALESCE(kays_credit, 0) + 200 WHERE id = NEW.id;
    INSERT INTO credit_transactions (buyer_id, amount, type, description, expires_at)
      VALUES (NEW.id, 200, 'cashback', '₦200 welcome bonus', now() + interval '90 days');
  END IF;
  RETURN NULL;
END;
$$;


ALTER FUNCTION "public"."grant_welcome_credit"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."guard_message_columns"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
BEGIN
  IF auth.role() = 'service_role'
     OR EXISTS (SELECT 1 FROM users u WHERE u.id = auth.uid() AND u.role = 'admin')
  THEN RETURN NEW; END IF;
  IF NEW.chat_id IS DISTINCT FROM OLD.chat_id
     OR NEW.sender_id IS DISTINCT FROM OLD.sender_id
     OR NEW.sender_role IS DISTINCT FROM OLD.sender_role
     OR NEW.content IS DISTINCT FROM OLD.content
     OR NEW.type IS DISTINCT FROM OLD.type
     OR NEW.reply_to_id IS DISTINCT FROM OLD.reply_to_id
     OR NEW.reply_to_content IS DISTINCT FROM OLD.reply_to_content
     OR NEW.reply_to_sender IS DISTINCT FROM OLD.reply_to_sender
     OR NEW.created_at IS DISTINCT FROM OLD.created_at
     OR NEW.delivery_fee_amount IS DISTINCT FROM OLD.delivery_fee_amount
     OR NEW.vendor_contribution IS DISTINCT FROM OLD.vendor_contribution
     OR NEW.buyer_fee_amount IS DISTINCT FROM OLD.buyer_fee_amount
  THEN RAISE EXCEPTION 'Only delivery_fee_status / read_at may be updated on a message'; END IF;
  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."guard_message_columns"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."guard_order_columns"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
BEGIN
  IF auth.role() = 'service_role'
     OR EXISTS (SELECT 1 FROM users u WHERE u.id = auth.uid() AND u.role = 'admin')
  THEN RETURN NEW; END IF;
  IF NEW.payment_released IS DISTINCT FROM OLD.payment_released
     OR NEW.payout_status IS DISTINCT FROM OLD.payout_status
     OR NEW.payout_attempts IS DISTINCT FROM OLD.payout_attempts
     OR NEW.total IS DISTINCT FROM OLD.total
     OR NEW.paid_at IS DISTINCT FROM OLD.paid_at
     OR NEW.refunded_at IS DISTINCT FROM OLD.refunded_at
     OR NEW.paystack_reference IS DISTINCT FROM OLD.paystack_reference
     OR NEW.payment_reference IS DISTINCT FROM OLD.payment_reference
  THEN RAISE EXCEPTION 'Not allowed to modify protected order fields'; END IF;
  IF NEW.has_dispute IS DISTINCT FROM OLD.has_dispute
     AND auth.uid() IS DISTINCT FROM OLD.buyer_id
  THEN RAISE EXCEPTION 'Not allowed to modify dispute state'; END IF;
  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."guard_order_columns"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."guard_user_columns"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
BEGIN
  IF auth.role() = 'service_role'
     OR current_setting('app.allow_credit', true) = '1'
     OR EXISTS (SELECT 1 FROM users u WHERE u.id = auth.uid() AND u.role = 'admin')
  THEN RETURN NEW; END IF;
  IF NEW.role IS DISTINCT FROM OLD.role
     OR NEW.kays_credit IS DISTINCT FROM OLD.kays_credit
     OR NEW.payout_blocked IS DISTINCT FROM OLD.payout_blocked
     OR NEW.payout_blocked_amount IS DISTINCT FROM OLD.payout_blocked_amount
     OR NEW.payout_blocked_reason IS DISTINCT FROM OLD.payout_blocked_reason
     OR NEW.active_dispute_id IS DISTINCT FROM OLD.active_dispute_id
     OR NEW.last_dispute_at IS DISTINCT FROM OLD.last_dispute_at
     OR NEW.last_dispute_vendor_id IS DISTINCT FROM OLD.last_dispute_vendor_id
     OR NEW.dispute_flagged IS DISTINCT FROM OLD.dispute_flagged
     OR NEW.dispute_flagged_at IS DISTINCT FROM OLD.dispute_flagged_at
     OR NEW.dispute_strikes_count IS DISTINCT FROM OLD.dispute_strikes_count
  THEN RAISE EXCEPTION 'Not allowed to modify protected user fields'; END IF;
  IF OLD.state IS NOT NULL AND NEW.state IS DISTINCT FROM OLD.state THEN
    RAISE EXCEPTION 'State is locked — use the state-change request flow'; END IF;
  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."guard_user_columns"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."increment_kays_credit"("p_user_id" "uuid", "p_amount" numeric) RETURNS numeric
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE result numeric;
BEGIN
  PERFORM set_config('app.allow_credit', '1', true);
  UPDATE users SET kays_credit = COALESCE(kays_credit, 0) + p_amount
   WHERE id = p_user_id RETURNING kays_credit INTO result;
  RETURN result;
END;
$$;


ALTER FUNCTION "public"."increment_kays_credit"("p_user_id" "uuid", "p_amount" numeric) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."is_admin"() RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    AS $$
  SELECT EXISTS (SELECT 1 FROM users WHERE id = auth.uid() AND role = 'admin');
$$;


ALTER FUNCTION "public"."is_admin"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."is_bank_account_locked"("p_user_id" "uuid") RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    AS $$
  SELECT EXISTS (
    SELECT 1 FROM vendor_bank_accounts
    WHERE user_id = p_user_id
    AND locked_until IS NOT NULL
    AND locked_until > now()
  );
$$;


ALTER FUNCTION "public"."is_bank_account_locked"("p_user_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."mark_chat_read"("p_chat_id" "uuid", "p_user_id" "uuid") RETURNS "void"
    LANGUAGE "sql" SECURITY DEFINER
    AS $$
  UPDATE messages
  SET read_at = now()
  WHERE chat_id = p_chat_id
    AND sender_id != p_user_id
    AND read_at IS NULL;
$$;


ALTER FUNCTION "public"."mark_chat_read"("p_chat_id" "uuid", "p_user_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."rls_auto_enable"() RETURNS "event_trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pg_catalog'
    AS $$
DECLARE
  cmd record;
BEGIN
  FOR cmd IN
    SELECT *
    FROM pg_event_trigger_ddl_commands()
    WHERE command_tag IN ('CREATE TABLE', 'CREATE TABLE AS', 'SELECT INTO')
      AND object_type IN ('table','partitioned table')
  LOOP
     IF cmd.schema_name IS NOT NULL AND cmd.schema_name IN ('public') AND cmd.schema_name NOT IN ('pg_catalog','information_schema') AND cmd.schema_name NOT LIKE 'pg_toast%' AND cmd.schema_name NOT LIKE 'pg_temp%' THEN
      BEGIN
        EXECUTE format('alter table if exists %s enable row level security', cmd.object_identity);
        RAISE LOG 'rls_auto_enable: enabled RLS on %', cmd.object_identity;
      EXCEPTION
        WHEN OTHERS THEN
          RAISE LOG 'rls_auto_enable: failed to enable RLS on %', cmd.object_identity;
      END;
     ELSE
        RAISE LOG 'rls_auto_enable: skip % (either system schema or not in enforced list: %.)', cmd.object_identity, cmd.schema_name;
     END IF;
  END LOOP;
END;
$$;


ALTER FUNCTION "public"."rls_auto_enable"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."set_product_vendor_state"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
  SELECT u.state INTO NEW.vendor_state
  FROM stores s
  JOIN users u ON u.id = s.vendor_id
  WHERE s.id = NEW.store_id;
  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."set_product_vendor_state"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."spend_kays_credit"("p_user_id" "uuid", "p_amount" numeric) RETURNS numeric
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE result numeric;
BEGIN
  IF auth.role() <> 'service_role' AND p_user_id <> auth.uid() THEN
    RAISE EXCEPTION 'Cannot spend another user''s credit';
  END IF;
  IF p_amount <= 0 THEN RAISE EXCEPTION 'Invalid amount'; END IF;
  PERFORM set_config('app.allow_credit', '1', true);
  UPDATE users SET kays_credit = kays_credit - p_amount
   WHERE id = p_user_id AND kays_credit >= p_amount
   RETURNING kays_credit INTO result;
  RETURN result;
END;
$$;


ALTER FUNCTION "public"."spend_kays_credit"("p_user_id" "uuid", "p_amount" numeric) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."touch_chat_member"("p_chat_id" "uuid", "p_kind" "text") RETURNS "void"
    LANGUAGE "sql" SECURITY DEFINER
    AS $$
  INSERT INTO chat_members (chat_id, user_id, last_read_at, last_delivered_at, updated_at)
  VALUES (p_chat_id, auth.uid(),
    CASE WHEN p_kind = 'read' THEN now() ELSE NULL END, now(), now())
  ON CONFLICT (chat_id, user_id) DO UPDATE SET
    last_delivered_at = now(),
    last_read_at = CASE WHEN p_kind = 'read' THEN now() ELSE chat_members.last_read_at END,
    updated_at = now();
$$;


ALTER FUNCTION "public"."touch_chat_member"("p_chat_id" "uuid", "p_kind" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."update_updated_at"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."update_updated_at"() OWNER TO "postgres";

SET default_tablespace = '';

SET default_table_access_method = "heap";


CREATE TABLE IF NOT EXISTS "public"."buyer_addresses" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "buyer_id" "uuid" NOT NULL,
    "label" "text" NOT NULL,
    "address" "text" NOT NULL,
    "landmark" "text" NOT NULL,
    "city" "text" NOT NULL,
    "state" "text" NOT NULL,
    "latitude" numeric,
    "longitude" numeric,
    "is_default" boolean DEFAULT false,
    "is_verified" boolean DEFAULT false,
    "created_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."buyer_addresses" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."buyer_bank_accounts" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "buyer_id" "uuid" NOT NULL,
    "bank_name" "text" NOT NULL,
    "bank_code" "text" NOT NULL,
    "account_number" "text" NOT NULL,
    "account_name" "text" NOT NULL,
    "paystack_recipient_code" "text",
    "is_verified" boolean DEFAULT false,
    "created_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."buyer_bank_accounts" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."cart_items" (
    "id" "uuid" DEFAULT "extensions"."uuid_generate_v4"() NOT NULL,
    "buyer_id" "uuid" NOT NULL,
    "product_id" "uuid" NOT NULL,
    "quantity" integer DEFAULT 1 NOT NULL,
    "added_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "variant_label" "text",
    "variant_price" numeric(12,2)
);


ALTER TABLE "public"."cart_items" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."chat_members" (
    "chat_id" "uuid" NOT NULL,
    "user_id" "uuid" NOT NULL,
    "last_read_at" timestamp with time zone,
    "last_delivered_at" timestamp with time zone,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."chat_members" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."chats" (
    "id" "uuid" DEFAULT "extensions"."uuid_generate_v4"() NOT NULL,
    "order_id" "text" NOT NULL,
    "buyer_id" "uuid" NOT NULL,
    "vendor_id" "uuid" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."chats" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."credit_transactions" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "buyer_id" "uuid" NOT NULL,
    "amount" numeric NOT NULL,
    "type" "text" NOT NULL,
    "order_id" "text",
    "description" "text",
    "expires_at" timestamp with time zone,
    "created_at" timestamp with time zone DEFAULT "now"(),
    CONSTRAINT "credit_transactions_type_check" CHECK (("type" = ANY (ARRAY['cashback'::"text", 'refund'::"text", 'used'::"text", 'expiry'::"text"])))
);


ALTER TABLE "public"."credit_transactions" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."deliveries" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "order_id" "uuid" NOT NULL,
    "vendor_id" "uuid" NOT NULL,
    "buyer_id" "uuid" NOT NULL,
    "shipbubble_order_id" "text",
    "courier_name" "text",
    "courier_phone" "text",
    "courier_email" "text",
    "tracking_code" "text",
    "tracking_url" "text",
    "pickup_address" "text" NOT NULL,
    "pickup_landmark" "text",
    "pickup_city" "text" NOT NULL,
    "pickup_latitude" numeric,
    "pickup_longitude" numeric,
    "delivery_address" "text" NOT NULL,
    "delivery_landmark" "text",
    "delivery_city" "text" NOT NULL,
    "delivery_latitude" numeric,
    "delivery_longitude" numeric,
    "delivery_note" "text",
    "item_name" "text" NOT NULL,
    "item_description" "text",
    "item_weight" numeric NOT NULL,
    "item_quantity" integer DEFAULT 1,
    "item_amount" numeric NOT NULL,
    "shipbubble_fee" numeric NOT NULL,
    "kays_markup" numeric DEFAULT 0,
    "buyer_charged" numeric NOT NULL,
    "status" "text" DEFAULT 'pending'::"text",
    "booked_at" timestamp with time zone DEFAULT "now"(),
    "confirmed_at" timestamp with time zone,
    "picked_up_at" timestamp with time zone,
    "delivered_at" timestamp with time zone,
    "estimated_delivery" "text",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "provider" "text" DEFAULT 'shipbubble'::"text",
    "provider_order_id" "text"
);


ALTER TABLE "public"."deliveries" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."delivery_quotes" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "order_id" "uuid",
    "vendor_id" "uuid",
    "buyer_id" "uuid",
    "pickup_address" "text" NOT NULL,
    "pickup_landmark" "text",
    "pickup_city" "text",
    "pickup_latitude" numeric,
    "pickup_longitude" numeric,
    "delivery_address" "text" NOT NULL,
    "delivery_landmark" "text",
    "delivery_city" "text",
    "delivery_latitude" numeric,
    "delivery_longitude" numeric,
    "item_weight" numeric NOT NULL,
    "sender_address_code" "text",
    "receiver_address_code" "text",
    "package_items" "jsonb",
    "available_couriers" "jsonb",
    "selected_courier_name" "text",
    "selected_service_code" "text",
    "selected_courier_id" "text",
    "selected_fee" numeric,
    "expires_at" timestamp with time zone,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "provider_data" "jsonb"
);


ALTER TABLE "public"."delivery_quotes" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."delivery_tracking" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "delivery_id" "uuid",
    "status" "text" NOT NULL,
    "description" "text",
    "location" "text",
    "timestamp" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."delivery_tracking" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."device_tokens" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid",
    "fcm_token" "text" NOT NULL,
    "platform" "text" DEFAULT 'android'::"text",
    "created_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."device_tokens" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."disputes" (
    "id" "uuid" DEFAULT "extensions"."uuid_generate_v4"() NOT NULL,
    "order_id" "uuid" NOT NULL,
    "raised_by" "uuid" NOT NULL,
    "reason" "text" NOT NULL,
    "status" "text" DEFAULT 'open'::"text" NOT NULL,
    "resolved_at" timestamp with time zone,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "buyer_id" "uuid",
    "vendor_id" "uuid",
    "buyer_phone" "text",
    "delivery_address" "text",
    "issue_type" "text",
    "evidence_urls" "text",
    "vendor_evidence_urls" "text",
    "resolution_deadline" timestamp with time zone,
    "escalated_to_admin" boolean DEFAULT false,
    "buyer_explanation" "text",
    "buyer_submitted_at" timestamp with time zone,
    "vendor_responded_at" timestamp with time zone,
    "resolution_type" "text",
    "vendor_response_deadline" timestamp with time zone,
    "admin_decision" "text",
    "admin_decided_by" "uuid",
    "admin_decided_at" timestamp with time zone,
    "admin_notes" "text",
    "return_required" boolean DEFAULT false,
    "return_deadline" timestamp with time zone,
    "return_package_photo_url" "text",
    "return_receipt_photo_url" "text",
    "return_uploaded_at" timestamp with time zone,
    "return_verified" boolean DEFAULT false,
    "return_verified_at" timestamp with time zone,
    "refund_method" "text",
    "video_url" "text",
    "auto_closed" boolean DEFAULT false,
    "return_receipt_photos" "text" DEFAULT '[]'::"text",
    "vendor_confirm_deadline" timestamp with time zone,
    "vendor_return_confirmed_at" timestamp with time zone,
    "vendor_return_received_photo" "text",
    "vendor_confirm_last_reminder_at" timestamp with time zone,
    "is_post_payment" boolean DEFAULT false,
    "vendor_owes_refund" numeric DEFAULT 0,
    CONSTRAINT "disputes_issue_type_check" CHECK (("issue_type" = ANY (ARRAY['wrong_item'::"text", 'damaged'::"text", 'not_as_described'::"text", 'not_received'::"text"]))),
    CONSTRAINT "disputes_status_check" CHECK (("status" = ANY (ARRAY['open'::"text", 'vendor_responded'::"text", 'evidence_submitted'::"text", 'replacement_offered'::"text", 'replacement_accepted'::"text", 'resolved'::"text", 'rejected'::"text", 'escalated'::"text", 'cancelled'::"text", 'awaiting_vendor_response'::"text", 'awaiting_admin_decision'::"text", 'awaiting_return'::"text", 'return_submitted'::"text", 'return_verified'::"text", 'refunded'::"text", 'denied'::"text", 'auto_closed'::"text", 'vendor_confirming'::"text"]))),
    CONSTRAINT "valid_resolution_type" CHECK (("resolution_type" = ANY (ARRAY['refund'::"text", 'replacement'::"text", 'partial_refund'::"text", 'rejected'::"text", 'escalated'::"text"])))
);


ALTER TABLE "public"."disputes" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."messages" (
    "id" "uuid" DEFAULT "extensions"."uuid_generate_v4"() NOT NULL,
    "chat_id" "uuid" NOT NULL,
    "sender_id" "uuid" NOT NULL,
    "sender_role" "text" NOT NULL,
    "content" "text" NOT NULL,
    "type" "text" DEFAULT 'text'::"text" NOT NULL,
    "reply_to_id" "uuid",
    "reply_to_content" "text",
    "reply_to_sender" "text",
    "read_at" timestamp with time zone,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "delivery_fee_amount" numeric,
    "vendor_contribution" numeric,
    "buyer_fee_amount" numeric,
    "delivery_fee_status" "text",
    CONSTRAINT "messages_sender_role_check" CHECK (("sender_role" = ANY (ARRAY['buyer'::"text", 'vendor'::"text", 'rider'::"text"]))),
    CONSTRAINT "messages_type_check" CHECK (("type" = ANY (ARRAY['text'::"text", 'image'::"text", 'video'::"text", 'product_card'::"text", 'delivery_fee_request'::"text", 'delivery_split_request'::"text"])))
);


ALTER TABLE "public"."messages" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."notifications" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "title" "text" NOT NULL,
    "body" "text" NOT NULL,
    "type" "text" DEFAULT 'general'::"text" NOT NULL,
    "reference_id" "text",
    "is_read" boolean DEFAULT false NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."notifications" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."orders" (
    "id" "uuid" DEFAULT "extensions"."uuid_generate_v4"() NOT NULL,
    "buyer_id" "uuid" NOT NULL,
    "vendor_id" "uuid" NOT NULL,
    "store_id" "uuid" NOT NULL,
    "items" "text" DEFAULT '[]'::"text" NOT NULL,
    "total" real NOT NULL,
    "status" "text" DEFAULT 'paid'::"text" NOT NULL,
    "shipping_method" "text",
    "tracking_ref" "text",
    "paid_at" timestamp with time zone,
    "shipped_at" timestamp with time zone,
    "delivered_at" timestamp with time zone,
    "confirmed_at" timestamp with time zone,
    "auto_release_at" timestamp with time zone,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "delivery_method" "text",
    "rider_name" "text",
    "rider_phone" "text",
    "shipping_proof_url" "text",
    "delivery_photo_url" "text",
    "payment_released" boolean DEFAULT false,
    "delivery_confirmed_at" timestamp with time zone,
    "paystack_reference" "text",
    "payment_reference" "text",
    "refunded_at" timestamp with time zone,
    "delivery_type" "text",
    "delivery_fee" numeric DEFAULT 0,
    "vendor_delivery_contribution" numeric DEFAULT 0,
    "total_with_delivery" numeric,
    "dispute_deadline" timestamp with time zone,
    "has_dispute" boolean DEFAULT false,
    "pre_ship_photos" "text" DEFAULT '[]'::"text",
    "admin_review_flagged" boolean DEFAULT false,
    "admin_review_flagged_at" timestamp with time zone,
    "extended_release_at" timestamp with time zone,
    "has_shipbubble_delivery" boolean DEFAULT false,
    "delivery_quote_id" "uuid",
    "delivery_id" "uuid",
    "selected_courier_name" "text",
    "selected_provider" "text",
    "pickup_deadline" timestamp with time zone,
    "pickup_reminded" boolean DEFAULT false,
    "payout_status" "text",
    "payout_attempts" integer DEFAULT 0 NOT NULL,
    CONSTRAINT "orders_status_check" CHECK (("status" = ANY (ARRAY['paid'::"text", 'shipped'::"text", 'delivered'::"text", 'confirmed'::"text", 'in_transit'::"text", 'courier_booked'::"text", 'refund_requested'::"text", 'refund_processing'::"text", 'refunded'::"text", 'auto_released'::"text", 'cancelled'::"text"])))
);


ALTER TABLE "public"."orders" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."policy_acceptances" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "role" "text" NOT NULL,
    "policy_version" "text" NOT NULL,
    "accepted_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."policy_acceptances" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."product_variants" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "product_id" "uuid",
    "label" "text" NOT NULL,
    "price" numeric(12,2) NOT NULL,
    "stock" integer DEFAULT 0 NOT NULL,
    "image_url" "text",
    "sort_order" integer DEFAULT 0 NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."product_variants" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."products" (
    "id" "uuid" DEFAULT "extensions"."uuid_generate_v4"() NOT NULL,
    "store_id" "uuid" NOT NULL,
    "name" "text" NOT NULL,
    "description" "text",
    "price" real NOT NULL,
    "images" "text" DEFAULT '[]'::"text" NOT NULL,
    "category" "text",
    "stock" integer DEFAULT 0 NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "vendor_state" "text",
    "delivery_type" "text" DEFAULT 'negotiate'::"text"
);


ALTER TABLE "public"."products" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."users" (
    "id" "uuid" DEFAULT "extensions"."uuid_generate_v4"() NOT NULL,
    "email" "text" NOT NULL,
    "password" "text" NOT NULL,
    "name" "text" NOT NULL,
    "role" "text" NOT NULL,
    "phone" "text",
    "nin" "text",
    "store_id" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "last_active" timestamp with time zone,
    "unique_id" "text",
    "address" "text",
    "kays_credit" numeric DEFAULT 0,
    "state" "text",
    "lga" "text",
    "dispute_strikes_count" integer DEFAULT 0,
    "dispute_flagged" boolean DEFAULT false,
    "dispute_flagged_at" timestamp with time zone,
    "active_dispute_id" "uuid",
    "last_dispute_at" timestamp with time zone,
    "last_dispute_vendor_id" "uuid",
    "vendor_warnings_count" integer DEFAULT 0,
    "vendor_flagged" boolean DEFAULT false,
    "vendor_flagged_at" timestamp with time zone,
    "payout_blocked" boolean DEFAULT false,
    "payout_blocked_reason" "text",
    "payout_blocked_amount" numeric DEFAULT 0,
    CONSTRAINT "users_role_check" CHECK (("role" = ANY (ARRAY['buyer'::"text", 'vendor'::"text", 'rider'::"text", 'admin'::"text"])))
);


ALTER TABLE "public"."users" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."public_profiles" AS
 SELECT "id",
    "name",
    "phone",
    "last_active",
    "unique_id"
   FROM "public"."users";


ALTER VIEW "public"."public_profiles" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."reviews" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "store_id" "uuid",
    "user_id" "uuid",
    "order_id" "uuid",
    "rating" integer NOT NULL,
    "comment" "text",
    "created_at" timestamp with time zone DEFAULT "now"(),
    CONSTRAINT "reviews_rating_check" CHECK ((("rating" >= 1) AND ("rating" <= 5)))
);


ALTER TABLE "public"."reviews" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."shipbubble_wallet" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "balance" numeric DEFAULT 0,
    "low_balance_threshold" numeric DEFAULT 50000,
    "last_checked_at" timestamp with time zone,
    "updated_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."shipbubble_wallet" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."state_change_requests" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "current_state" "text",
    "requested_state" "text" NOT NULL,
    "reason" "text" NOT NULL,
    "status" "text" DEFAULT 'pending'::"text" NOT NULL,
    "admin_note" "text",
    "reviewed_by" "uuid",
    "reviewed_at" timestamp with time zone,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "state_change_requests_status_check" CHECK (("status" = ANY (ARRAY['pending'::"text", 'approved'::"text", 'rejected'::"text"])))
);


ALTER TABLE "public"."state_change_requests" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."stores" (
    "id" "uuid" DEFAULT "extensions"."uuid_generate_v4"() NOT NULL,
    "vendor_id" "uuid" NOT NULL,
    "name" "text" NOT NULL,
    "description" "text",
    "logo_path" "text",
    "address" "text",
    "phone" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "whatsapp_number" "text",
    "show_phone_to_buyers" boolean DEFAULT true,
    "store_banner_url" "text",
    "response_time" "text",
    "is_verified" boolean DEFAULT false,
    "handle" "text"
);


ALTER TABLE "public"."stores" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."transactions" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "order_id" "uuid",
    "buyer_id" "uuid",
    "vendor_id" "uuid",
    "store_id" "uuid",
    "amount" numeric NOT NULL,
    "platform_fee" numeric DEFAULT 0 NOT NULL,
    "vendor_payout" numeric DEFAULT 0 NOT NULL,
    "paystack_reference" "text",
    "paystack_access_code" "text",
    "paystack_authorization_url" "text",
    "channel" "text" DEFAULT 'card'::"text",
    "status" "text" DEFAULT 'pending'::"text" NOT NULL,
    "type" "text" DEFAULT 'payment'::"text" NOT NULL,
    "metadata" "jsonb" DEFAULT '{}'::"jsonb",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."transactions" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."vendor_bank_accounts" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid",
    "bank_name" "text" NOT NULL,
    "bank_code" "text" NOT NULL,
    "account_number" "text" NOT NULL,
    "account_name" "text" DEFAULT ''::"text" NOT NULL,
    "paystack_recipient_code" "text",
    "is_verified" boolean DEFAULT false,
    "locked_until" timestamp with time zone,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."vendor_bank_accounts" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."vendor_charges" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "vendor_id" "uuid" NOT NULL,
    "order_id" "uuid",
    "amount" numeric NOT NULL,
    "reason" "text" NOT NULL,
    "status" "text" DEFAULT 'pending'::"text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "settled_at" timestamp with time zone
);


ALTER TABLE "public"."vendor_charges" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."vendor_locations" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "vendor_id" "uuid" NOT NULL,
    "label" "text" NOT NULL,
    "address" "text" NOT NULL,
    "landmark" "text" NOT NULL,
    "city" "text" NOT NULL,
    "state" "text" NOT NULL,
    "latitude" numeric,
    "longitude" numeric,
    "is_default" boolean DEFAULT false,
    "is_verified" boolean DEFAULT false,
    "created_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."vendor_locations" OWNER TO "postgres";


ALTER TABLE ONLY "public"."buyer_addresses"
    ADD CONSTRAINT "buyer_addresses_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."buyer_bank_accounts"
    ADD CONSTRAINT "buyer_bank_accounts_buyer_id_key" UNIQUE ("buyer_id");



ALTER TABLE ONLY "public"."buyer_bank_accounts"
    ADD CONSTRAINT "buyer_bank_accounts_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."cart_items"
    ADD CONSTRAINT "cart_items_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."chat_members"
    ADD CONSTRAINT "chat_members_pkey" PRIMARY KEY ("chat_id", "user_id");



ALTER TABLE ONLY "public"."chats"
    ADD CONSTRAINT "chats_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."credit_transactions"
    ADD CONSTRAINT "credit_transactions_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."deliveries"
    ADD CONSTRAINT "deliveries_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."delivery_quotes"
    ADD CONSTRAINT "delivery_quotes_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."delivery_tracking"
    ADD CONSTRAINT "delivery_tracking_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."device_tokens"
    ADD CONSTRAINT "device_tokens_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."device_tokens"
    ADD CONSTRAINT "device_tokens_user_id_platform_key" UNIQUE ("user_id", "platform");



ALTER TABLE ONLY "public"."disputes"
    ADD CONSTRAINT "disputes_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."messages"
    ADD CONSTRAINT "messages_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."notifications"
    ADD CONSTRAINT "notifications_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."orders"
    ADD CONSTRAINT "orders_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."policy_acceptances"
    ADD CONSTRAINT "policy_acceptances_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."product_variants"
    ADD CONSTRAINT "product_variants_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."products"
    ADD CONSTRAINT "products_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."reviews"
    ADD CONSTRAINT "reviews_order_id_user_id_key" UNIQUE ("order_id", "user_id");



ALTER TABLE ONLY "public"."reviews"
    ADD CONSTRAINT "reviews_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."shipbubble_wallet"
    ADD CONSTRAINT "shipbubble_wallet_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."state_change_requests"
    ADD CONSTRAINT "state_change_requests_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."stores"
    ADD CONSTRAINT "stores_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."transactions"
    ADD CONSTRAINT "transactions_paystack_reference_key" UNIQUE ("paystack_reference");



ALTER TABLE ONLY "public"."transactions"
    ADD CONSTRAINT "transactions_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."users"
    ADD CONSTRAINT "users_email_key" UNIQUE ("email");



ALTER TABLE ONLY "public"."users"
    ADD CONSTRAINT "users_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."vendor_bank_accounts"
    ADD CONSTRAINT "vendor_bank_accounts_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."vendor_bank_accounts"
    ADD CONSTRAINT "vendor_bank_accounts_user_id_key" UNIQUE ("user_id");



ALTER TABLE ONLY "public"."vendor_charges"
    ADD CONSTRAINT "vendor_charges_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."vendor_locations"
    ADD CONSTRAINT "vendor_locations_pkey" PRIMARY KEY ("id");



CREATE INDEX "idx_buyer_addresses_buyer" ON "public"."buyer_addresses" USING "btree" ("buyer_id");



CREATE INDEX "idx_cart_buyer" ON "public"."cart_items" USING "btree" ("buyer_id");



CREATE INDEX "idx_cart_items_buyer_id" ON "public"."cart_items" USING "btree" ("buyer_id");



CREATE INDEX "idx_chat_members_chat" ON "public"."chat_members" USING "btree" ("chat_id");



CREATE INDEX "idx_chats_buyer" ON "public"."chats" USING "btree" ("buyer_id");



CREATE INDEX "idx_chats_buyer_id" ON "public"."chats" USING "btree" ("buyer_id");



CREATE INDEX "idx_chats_buyer_vendor" ON "public"."chats" USING "btree" ("buyer_id", "vendor_id");



CREATE INDEX "idx_chats_order_id" ON "public"."chats" USING "btree" ("order_id");



CREATE INDEX "idx_chats_vendor" ON "public"."chats" USING "btree" ("vendor_id");



CREATE INDEX "idx_chats_vendor_id" ON "public"."chats" USING "btree" ("vendor_id");



CREATE INDEX "idx_credit_tx_buyer" ON "public"."credit_transactions" USING "btree" ("buyer_id");



CREATE INDEX "idx_deliveries_order" ON "public"."deliveries" USING "btree" ("order_id");



CREATE INDEX "idx_deliveries_provider_order" ON "public"."deliveries" USING "btree" ("provider_order_id");



CREATE INDEX "idx_deliveries_shipbubble_order" ON "public"."deliveries" USING "btree" ("shipbubble_order_id");



CREATE INDEX "idx_delivery_quotes_buyer" ON "public"."delivery_quotes" USING "btree" ("buyer_id");



CREATE INDEX "idx_delivery_tracking_delivery" ON "public"."delivery_tracking" USING "btree" ("delivery_id");



CREATE INDEX "idx_device_tokens_user_id" ON "public"."device_tokens" USING "btree" ("user_id");



CREATE INDEX "idx_disputes_buyer_created" ON "public"."disputes" USING "btree" ("buyer_id", "created_at" DESC);



CREATE INDEX "idx_disputes_buyer_id" ON "public"."disputes" USING "btree" ("buyer_id");



CREATE INDEX "idx_disputes_deadline" ON "public"."disputes" USING "btree" ("resolution_deadline") WHERE ("status" = 'open'::"text");



CREATE INDEX "idx_disputes_order_id" ON "public"."disputes" USING "btree" ("order_id");



CREATE INDEX "idx_disputes_status" ON "public"."disputes" USING "btree" ("status");



CREATE INDEX "idx_disputes_vendor_created" ON "public"."disputes" USING "btree" ("vendor_id", "created_at" DESC);



CREATE INDEX "idx_disputes_vendor_id" ON "public"."disputes" USING "btree" ("vendor_id");



CREATE INDEX "idx_messages_chat_created" ON "public"."messages" USING "btree" ("chat_id", "created_at" DESC);



CREATE INDEX "idx_messages_chat_id" ON "public"."messages" USING "btree" ("chat_id");



CREATE INDEX "idx_messages_chat_read" ON "public"."messages" USING "btree" ("chat_id", "read_at") WHERE ("read_at" IS NULL);



CREATE INDEX "idx_messages_chat_sender_read" ON "public"."messages" USING "btree" ("chat_id", "sender_id", "read_at");



CREATE INDEX "idx_messages_created_at" ON "public"."messages" USING "btree" ("created_at");



CREATE INDEX "idx_notifications_created_at" ON "public"."notifications" USING "btree" ("created_at" DESC);



CREATE INDEX "idx_notifications_user_id" ON "public"."notifications" USING "btree" ("user_id");



CREATE INDEX "idx_notifications_user_read" ON "public"."notifications" USING "btree" ("user_id", "is_read");



CREATE INDEX "idx_orders_admin_review_flagged" ON "public"."orders" USING "btree" ("admin_review_flagged") WHERE ("admin_review_flagged" = true);



CREATE INDEX "idx_orders_buyer_created" ON "public"."orders" USING "btree" ("buyer_id", "created_at" DESC);



CREATE INDEX "idx_orders_buyer_id" ON "public"."orders" USING "btree" ("buyer_id");



CREATE INDEX "idx_orders_dispute_deadline" ON "public"."orders" USING "btree" ("dispute_deadline");



CREATE INDEX "idx_orders_payment_reference" ON "public"."orders" USING "btree" ("payment_reference");



CREATE INDEX "idx_orders_payout_attention" ON "public"."orders" USING "btree" ("payout_status") WHERE ("payout_status" = ANY (ARRAY['failed'::"text", 'pending_bank'::"text"]));



CREATE UNIQUE INDEX "idx_orders_paystack_reference" ON "public"."orders" USING "btree" ("paystack_reference") WHERE ("paystack_reference" IS NOT NULL);



CREATE INDEX "idx_orders_pickup_deadline" ON "public"."orders" USING "btree" ("pickup_deadline") WHERE ("pickup_deadline" IS NOT NULL);



CREATE INDEX "idx_orders_status" ON "public"."orders" USING "btree" ("status");



CREATE INDEX "idx_orders_store_id" ON "public"."orders" USING "btree" ("store_id");



CREATE INDEX "idx_orders_vendor_created" ON "public"."orders" USING "btree" ("vendor_id", "created_at" DESC);



CREATE INDEX "idx_orders_vendor_id" ON "public"."orders" USING "btree" ("vendor_id");



CREATE INDEX "idx_products_category" ON "public"."products" USING "btree" ("category");



CREATE INDEX "idx_products_category_created" ON "public"."products" USING "btree" ("category", "created_at" DESC);



CREATE INDEX "idx_products_created_at" ON "public"."products" USING "btree" ("created_at" DESC);



CREATE INDEX "idx_products_desc_gin" ON "public"."products" USING "gin" ("description" "public"."gin_trgm_ops");



CREATE INDEX "idx_products_name_gin" ON "public"."products" USING "gin" ("name" "public"."gin_trgm_ops");



CREATE INDEX "idx_products_store_id" ON "public"."products" USING "btree" ("store_id");



CREATE INDEX "idx_products_vendor_state" ON "public"."products" USING "btree" ("vendor_state");



CREATE INDEX "idx_reviews_order_user" ON "public"."reviews" USING "btree" ("order_id", "user_id");



CREATE INDEX "idx_reviews_store_created" ON "public"."reviews" USING "btree" ("store_id", "created_at" DESC);



CREATE INDEX "idx_reviews_store_id" ON "public"."reviews" USING "btree" ("store_id");



CREATE INDEX "idx_state_change_requests_status" ON "public"."state_change_requests" USING "btree" ("status");



CREATE INDEX "idx_state_change_requests_user" ON "public"."state_change_requests" USING "btree" ("user_id");



CREATE INDEX "idx_stores_vendor" ON "public"."stores" USING "btree" ("vendor_id");



CREATE INDEX "idx_transactions_buyer_id" ON "public"."transactions" USING "btree" ("buyer_id");



CREATE INDEX "idx_transactions_created_at" ON "public"."transactions" USING "btree" ("created_at" DESC);



CREATE INDEX "idx_transactions_order_id" ON "public"."transactions" USING "btree" ("order_id");



CREATE INDEX "idx_transactions_paystack_ref" ON "public"."transactions" USING "btree" ("paystack_reference");



CREATE INDEX "idx_transactions_paystack_reference" ON "public"."transactions" USING "btree" ("paystack_reference");



CREATE INDEX "idx_transactions_status" ON "public"."transactions" USING "btree" ("status");



CREATE INDEX "idx_transactions_vendor_id" ON "public"."transactions" USING "btree" ("vendor_id");



CREATE INDEX "idx_users_last_active" ON "public"."users" USING "btree" ("last_active" DESC);



CREATE INDEX "idx_users_state" ON "public"."users" USING "btree" ("state");



CREATE UNIQUE INDEX "idx_users_unique_id" ON "public"."users" USING "btree" ("unique_id") WHERE ("unique_id" IS NOT NULL);



CREATE INDEX "idx_variants_product" ON "public"."product_variants" USING "btree" ("product_id", "sort_order");



CREATE INDEX "idx_vendor_bank_accounts_user" ON "public"."vendor_bank_accounts" USING "btree" ("user_id");



CREATE INDEX "idx_vendor_charges_pending" ON "public"."vendor_charges" USING "btree" ("vendor_id") WHERE ("status" = 'pending'::"text");



CREATE INDEX "idx_vendor_locations_vendor" ON "public"."vendor_locations" USING "btree" ("vendor_id");



CREATE UNIQUE INDEX "uniq_active_delivery_per_order" ON "public"."deliveries" USING "btree" ("order_id") WHERE ("status" <> ALL (ARRAY['cancelled'::"text", 'failed'::"text"]));



CREATE UNIQUE INDEX "uniq_policy_acceptance_user_version" ON "public"."policy_acceptances" USING "btree" ("user_id", "policy_version");



CREATE UNIQUE INDEX "uniq_store_handle" ON "public"."stores" USING "btree" ("handle");



CREATE UNIQUE INDEX "uniq_vendor_charge_order_reason" ON "public"."vendor_charges" USING "btree" ("order_id", "reason");



CREATE OR REPLACE TRIGGER "auto_set_product_vendor_state" BEFORE INSERT OR UPDATE OF "store_id" ON "public"."products" FOR EACH ROW EXECUTE FUNCTION "public"."set_product_vendor_state"();



CREATE OR REPLACE TRIGGER "transactions_updated_at" BEFORE UPDATE ON "public"."transactions" FOR EACH ROW EXECUTE FUNCTION "public"."update_updated_at"();



CREATE OR REPLACE TRIGGER "trg_grant_welcome_credit" AFTER INSERT ON "public"."users" FOR EACH ROW EXECUTE FUNCTION "public"."grant_welcome_credit"();



CREATE OR REPLACE TRIGGER "trg_guard_message_columns" BEFORE UPDATE ON "public"."messages" FOR EACH ROW EXECUTE FUNCTION "public"."guard_message_columns"();



CREATE OR REPLACE TRIGGER "trg_guard_order_columns" BEFORE UPDATE ON "public"."orders" FOR EACH ROW EXECUTE FUNCTION "public"."guard_order_columns"();



CREATE OR REPLACE TRIGGER "trg_guard_user_columns" BEFORE UPDATE ON "public"."users" FOR EACH ROW EXECUTE FUNCTION "public"."guard_user_columns"();



CREATE OR REPLACE TRIGGER "vendor_bank_accounts_updated_at" BEFORE UPDATE ON "public"."vendor_bank_accounts" FOR EACH ROW EXECUTE FUNCTION "public"."update_updated_at"();



ALTER TABLE ONLY "public"."buyer_addresses"
    ADD CONSTRAINT "buyer_addresses_buyer_id_fkey" FOREIGN KEY ("buyer_id") REFERENCES "public"."users"("id");



ALTER TABLE ONLY "public"."buyer_bank_accounts"
    ADD CONSTRAINT "buyer_bank_accounts_buyer_id_fkey" FOREIGN KEY ("buyer_id") REFERENCES "public"."users"("id");



ALTER TABLE ONLY "public"."cart_items"
    ADD CONSTRAINT "cart_items_buyer_id_fkey" FOREIGN KEY ("buyer_id") REFERENCES "public"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."cart_items"
    ADD CONSTRAINT "cart_items_product_id_fkey" FOREIGN KEY ("product_id") REFERENCES "public"."products"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."chat_members"
    ADD CONSTRAINT "chat_members_chat_id_fkey" FOREIGN KEY ("chat_id") REFERENCES "public"."chats"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."chat_members"
    ADD CONSTRAINT "chat_members_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."chats"
    ADD CONSTRAINT "chats_buyer_id_fkey" FOREIGN KEY ("buyer_id") REFERENCES "public"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."chats"
    ADD CONSTRAINT "chats_vendor_id_fkey" FOREIGN KEY ("vendor_id") REFERENCES "public"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."credit_transactions"
    ADD CONSTRAINT "credit_transactions_buyer_id_fkey" FOREIGN KEY ("buyer_id") REFERENCES "public"."users"("id");



ALTER TABLE ONLY "public"."deliveries"
    ADD CONSTRAINT "deliveries_buyer_id_fkey" FOREIGN KEY ("buyer_id") REFERENCES "public"."users"("id");



ALTER TABLE ONLY "public"."deliveries"
    ADD CONSTRAINT "deliveries_order_id_fkey" FOREIGN KEY ("order_id") REFERENCES "public"."orders"("id");



ALTER TABLE ONLY "public"."deliveries"
    ADD CONSTRAINT "deliveries_vendor_id_fkey" FOREIGN KEY ("vendor_id") REFERENCES "public"."users"("id");



ALTER TABLE ONLY "public"."delivery_quotes"
    ADD CONSTRAINT "delivery_quotes_buyer_id_fkey" FOREIGN KEY ("buyer_id") REFERENCES "public"."users"("id");



ALTER TABLE ONLY "public"."delivery_quotes"
    ADD CONSTRAINT "delivery_quotes_order_id_fkey" FOREIGN KEY ("order_id") REFERENCES "public"."orders"("id");



ALTER TABLE ONLY "public"."delivery_quotes"
    ADD CONSTRAINT "delivery_quotes_vendor_id_fkey" FOREIGN KEY ("vendor_id") REFERENCES "public"."users"("id");



ALTER TABLE ONLY "public"."delivery_tracking"
    ADD CONSTRAINT "delivery_tracking_delivery_id_fkey" FOREIGN KEY ("delivery_id") REFERENCES "public"."deliveries"("id");



ALTER TABLE ONLY "public"."device_tokens"
    ADD CONSTRAINT "device_tokens_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."disputes"
    ADD CONSTRAINT "disputes_admin_decided_by_fkey" FOREIGN KEY ("admin_decided_by") REFERENCES "public"."users"("id");



ALTER TABLE ONLY "public"."disputes"
    ADD CONSTRAINT "disputes_buyer_id_fkey" FOREIGN KEY ("buyer_id") REFERENCES "public"."users"("id");



ALTER TABLE ONLY "public"."disputes"
    ADD CONSTRAINT "disputes_order_id_fkey" FOREIGN KEY ("order_id") REFERENCES "public"."orders"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."disputes"
    ADD CONSTRAINT "disputes_raised_by_fkey" FOREIGN KEY ("raised_by") REFERENCES "public"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."disputes"
    ADD CONSTRAINT "disputes_vendor_id_fkey" FOREIGN KEY ("vendor_id") REFERENCES "public"."users"("id");



ALTER TABLE ONLY "public"."users"
    ADD CONSTRAINT "fk_users_store" FOREIGN KEY ("store_id") REFERENCES "public"."stores"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."messages"
    ADD CONSTRAINT "messages_chat_id_fkey" FOREIGN KEY ("chat_id") REFERENCES "public"."chats"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."messages"
    ADD CONSTRAINT "messages_reply_to_id_fkey" FOREIGN KEY ("reply_to_id") REFERENCES "public"."messages"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."messages"
    ADD CONSTRAINT "messages_sender_id_fkey" FOREIGN KEY ("sender_id") REFERENCES "public"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."notifications"
    ADD CONSTRAINT "notifications_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."orders"
    ADD CONSTRAINT "orders_buyer_id_fkey" FOREIGN KEY ("buyer_id") REFERENCES "public"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."orders"
    ADD CONSTRAINT "orders_store_id_fkey" FOREIGN KEY ("store_id") REFERENCES "public"."stores"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."orders"
    ADD CONSTRAINT "orders_vendor_id_fkey" FOREIGN KEY ("vendor_id") REFERENCES "public"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."policy_acceptances"
    ADD CONSTRAINT "policy_acceptances_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."product_variants"
    ADD CONSTRAINT "product_variants_product_id_fkey" FOREIGN KEY ("product_id") REFERENCES "public"."products"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."products"
    ADD CONSTRAINT "products_store_id_fkey" FOREIGN KEY ("store_id") REFERENCES "public"."stores"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."reviews"
    ADD CONSTRAINT "reviews_order_id_fkey" FOREIGN KEY ("order_id") REFERENCES "public"."orders"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."reviews"
    ADD CONSTRAINT "reviews_store_id_fkey" FOREIGN KEY ("store_id") REFERENCES "public"."stores"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."reviews"
    ADD CONSTRAINT "reviews_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."state_change_requests"
    ADD CONSTRAINT "state_change_requests_reviewed_by_fkey" FOREIGN KEY ("reviewed_by") REFERENCES "public"."users"("id");



ALTER TABLE ONLY "public"."state_change_requests"
    ADD CONSTRAINT "state_change_requests_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."stores"
    ADD CONSTRAINT "stores_vendor_id_fkey" FOREIGN KEY ("vendor_id") REFERENCES "public"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."transactions"
    ADD CONSTRAINT "transactions_buyer_id_fkey" FOREIGN KEY ("buyer_id") REFERENCES "public"."users"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."transactions"
    ADD CONSTRAINT "transactions_order_id_fkey" FOREIGN KEY ("order_id") REFERENCES "public"."orders"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."transactions"
    ADD CONSTRAINT "transactions_store_id_fkey" FOREIGN KEY ("store_id") REFERENCES "public"."stores"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."transactions"
    ADD CONSTRAINT "transactions_vendor_id_fkey" FOREIGN KEY ("vendor_id") REFERENCES "public"."users"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."vendor_bank_accounts"
    ADD CONSTRAINT "vendor_bank_accounts_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."vendor_charges"
    ADD CONSTRAINT "vendor_charges_order_id_fkey" FOREIGN KEY ("order_id") REFERENCES "public"."orders"("id");



ALTER TABLE ONLY "public"."vendor_charges"
    ADD CONSTRAINT "vendor_charges_vendor_id_fkey" FOREIGN KEY ("vendor_id") REFERENCES "public"."users"("id");



ALTER TABLE ONLY "public"."vendor_locations"
    ADD CONSTRAINT "vendor_locations_vendor_id_fkey" FOREIGN KEY ("vendor_id") REFERENCES "public"."users"("id");



CREATE POLICY "Admins read all users" ON "public"."users" FOR SELECT USING ("public"."is_admin"());



CREATE POLICY "Admins update any user state" ON "public"."users" FOR UPDATE USING ((EXISTS ( SELECT 1
   FROM "public"."users" "u"
  WHERE (("u"."id" = "auth"."uid"()) AND ("u"."role" = 'admin'::"text")))));



CREATE POLICY "Admins update state requests" ON "public"."state_change_requests" FOR UPDATE USING ((EXISTS ( SELECT 1
   FROM "public"."users" "u"
  WHERE (("u"."id" = "auth"."uid"()) AND ("u"."role" = 'admin'::"text")))));



CREATE POLICY "Admins view all state requests" ON "public"."state_change_requests" FOR SELECT USING ((EXISTS ( SELECT 1
   FROM "public"."users" "u"
  WHERE (("u"."id" = "auth"."uid"()) AND ("u"."role" = 'admin'::"text")))));



CREATE POLICY "Anyone can read reviews" ON "public"."reviews" FOR SELECT USING (true);



CREATE POLICY "Anyone can view variants" ON "public"."product_variants" FOR SELECT USING (true);



CREATE POLICY "Authenticated users can insert reviews" ON "public"."reviews" FOR INSERT WITH CHECK (("auth"."uid"() = "user_id"));



CREATE POLICY "Buyers read own bank" ON "public"."buyer_bank_accounts" FOR SELECT USING (("buyer_id" = "auth"."uid"()));



CREATE POLICY "Buyers read own credits" ON "public"."credit_transactions" FOR SELECT USING (("buyer_id" = "auth"."uid"()));



CREATE POLICY "Buyers update own bank" ON "public"."buyer_bank_accounts" FOR UPDATE USING (("buyer_id" = "auth"."uid"())) WITH CHECK (("buyer_id" = "auth"."uid"()));



CREATE POLICY "Buyers upsert own bank" ON "public"."buyer_bank_accounts" FOR INSERT WITH CHECK (("buyer_id" = "auth"."uid"()));



CREATE POLICY "Buyers view own transactions" ON "public"."transactions" FOR SELECT USING (("auth"."uid"() = "buyer_id"));



CREATE POLICY "Cart owner delete" ON "public"."cart_items" FOR DELETE USING (("auth"."uid"() = "buyer_id"));



CREATE POLICY "Cart owner insert" ON "public"."cart_items" FOR INSERT WITH CHECK (("auth"."uid"() = "buyer_id"));



CREATE POLICY "Cart owner read" ON "public"."cart_items" FOR SELECT USING (("auth"."uid"() = "buyer_id"));



CREATE POLICY "Chats insert" ON "public"."chats" FOR INSERT WITH CHECK ((("auth"."uid"() = "buyer_id") OR ("auth"."uid"() = "vendor_id")));



CREATE POLICY "Chats read" ON "public"."chats" FOR SELECT USING ((("auth"."uid"() = "buyer_id") OR ("auth"."uid"() = "vendor_id")));



CREATE POLICY "Disputes insert" ON "public"."disputes" FOR INSERT WITH CHECK (("auth"."uid"() = "raised_by"));



CREATE POLICY "Disputes read" ON "public"."disputes" FOR SELECT USING ((("auth"."uid"() = "raised_by") OR ("auth"."uid"() IN ( SELECT "orders"."buyer_id"
   FROM "public"."orders"
  WHERE ("orders"."id" = "disputes"."order_id")
UNION
 SELECT "orders"."vendor_id"
   FROM "public"."orders"
  WHERE ("orders"."id" = "disputes"."order_id")))));



CREATE POLICY "Insert notifications for self or counterparties" ON "public"."notifications" FOR INSERT WITH CHECK ((("auth"."uid"() = "user_id") OR "public"."is_admin"() OR (EXISTS ( SELECT 1
   FROM "public"."chats" "c"
  WHERE ((("c"."buyer_id" = "auth"."uid"()) AND ("c"."vendor_id" = "notifications"."user_id")) OR (("c"."vendor_id" = "auth"."uid"()) AND ("c"."buyer_id" = "notifications"."user_id"))))) OR (EXISTS ( SELECT 1
   FROM "public"."orders" "o"
  WHERE ((("o"."buyer_id" = "auth"."uid"()) AND ("o"."vendor_id" = "notifications"."user_id")) OR (("o"."vendor_id" = "auth"."uid"()) AND ("o"."buyer_id" = "notifications"."user_id")))))));



CREATE POLICY "Messages insert" ON "public"."messages" FOR INSERT WITH CHECK (("auth"."uid"() = "sender_id"));



CREATE POLICY "Messages read" ON "public"."messages" FOR SELECT USING (("chat_id" IN ( SELECT "chats"."id"
   FROM "public"."chats"
  WHERE (("chats"."buyer_id" = "auth"."uid"()) OR ("chats"."vendor_id" = "auth"."uid"())))));



CREATE POLICY "Messages update" ON "public"."messages" FOR UPDATE USING (("chat_id" IN ( SELECT "chats"."id"
   FROM "public"."chats"
  WHERE (("chats"."buyer_id" = "auth"."uid"()) OR ("chats"."vendor_id" = "auth"."uid"())))));



CREATE POLICY "Orders buyer insert" ON "public"."orders" FOR INSERT WITH CHECK (("auth"."uid"() = "buyer_id"));



CREATE POLICY "Orders buyer read" ON "public"."orders" FOR SELECT USING (("auth"."uid"() = "buyer_id"));



CREATE POLICY "Orders buyer update" ON "public"."orders" FOR UPDATE USING (("auth"."uid"() = "buyer_id"));



CREATE POLICY "Orders vendor read" ON "public"."orders" FOR SELECT USING (("auth"."uid"() = "vendor_id"));



CREATE POLICY "Orders vendor update" ON "public"."orders" FOR UPDATE USING (("auth"."uid"() = "vendor_id"));



CREATE POLICY "Products owner delete" ON "public"."products" FOR DELETE USING (("store_id" IN ( SELECT "stores"."id"
   FROM "public"."stores"
  WHERE ("stores"."vendor_id" = "auth"."uid"()))));



CREATE POLICY "Products owner insert" ON "public"."products" FOR INSERT WITH CHECK (("store_id" IN ( SELECT "stores"."id"
   FROM "public"."stores"
  WHERE ("stores"."vendor_id" = "auth"."uid"()))));



CREATE POLICY "Products owner update" ON "public"."products" FOR UPDATE USING (("store_id" IN ( SELECT "stores"."id"
   FROM "public"."stores"
  WHERE ("stores"."vendor_id" = "auth"."uid"()))));



CREATE POLICY "Products public read" ON "public"."products" FOR SELECT USING (true);



CREATE POLICY "Service role can read all tokens" ON "public"."device_tokens" FOR SELECT TO "service_role" USING (true);



CREATE POLICY "Service role manages bank accounts" ON "public"."vendor_bank_accounts" TO "service_role" USING (true) WITH CHECK (true);



CREATE POLICY "Service role manages credit transactions" ON "public"."credit_transactions" TO "service_role" USING (true) WITH CHECK (true);



CREATE POLICY "Service role manages transactions" ON "public"."transactions" TO "service_role" USING (true) WITH CHECK (true);



CREATE POLICY "Stores owner insert" ON "public"."stores" FOR INSERT WITH CHECK (("auth"."uid"() = "vendor_id"));



CREATE POLICY "Stores owner update" ON "public"."stores" FOR UPDATE USING (("auth"."uid"() = "vendor_id"));



CREATE POLICY "Stores public read" ON "public"."stores" FOR SELECT USING (true);



CREATE POLICY "Users can manage own device tokens" ON "public"."device_tokens" USING (("auth"."uid"() = "user_id"));



CREATE POLICY "Users create own state requests" ON "public"."state_change_requests" FOR INSERT WITH CHECK (("user_id" = "auth"."uid"()));



CREATE POLICY "Users delete own notifications" ON "public"."notifications" FOR DELETE USING (("auth"."uid"() = "user_id"));



CREATE POLICY "Users insert" ON "public"."users" FOR INSERT WITH CHECK (("auth"."uid"() = "id"));



CREATE POLICY "Users read own" ON "public"."users" FOR SELECT USING (("auth"."uid"() = "id"));



CREATE POLICY "Users read own notifications" ON "public"."notifications" FOR SELECT USING (("auth"."uid"() = "user_id"));



CREATE POLICY "Users update own" ON "public"."users" FOR UPDATE USING (("auth"."uid"() = "id"));



CREATE POLICY "Users update own notifications" ON "public"."notifications" FOR UPDATE USING (("auth"."uid"() = "user_id"));



CREATE POLICY "Users view own state requests" ON "public"."state_change_requests" FOR SELECT USING (("user_id" = "auth"."uid"()));



CREATE POLICY "Vendors insert own bank account" ON "public"."vendor_bank_accounts" FOR INSERT WITH CHECK (("auth"."uid"() = "user_id"));



CREATE POLICY "Vendors manage own product variants" ON "public"."product_variants" USING ((EXISTS ( SELECT 1
   FROM ("public"."products" "p"
     JOIN "public"."stores" "s" ON (("s"."id" = "p"."store_id")))
  WHERE (("p"."id" = "product_variants"."product_id") AND ("s"."vendor_id" = "auth"."uid"()))))) WITH CHECK ((EXISTS ( SELECT 1
   FROM ("public"."products" "p"
     JOIN "public"."stores" "s" ON (("s"."id" = "p"."store_id")))
  WHERE (("p"."id" = "product_variants"."product_id") AND ("s"."vendor_id" = "auth"."uid"())))));



CREATE POLICY "Vendors update own bank account" ON "public"."vendor_bank_accounts" FOR UPDATE USING (("auth"."uid"() = "user_id")) WITH CHECK (("auth"."uid"() = "user_id"));



CREATE POLICY "Vendors view own bank account" ON "public"."vendor_bank_accounts" FOR SELECT USING (("auth"."uid"() = "user_id"));



CREATE POLICY "Vendors view own transactions" ON "public"."transactions" FOR SELECT USING (("auth"."uid"() = "vendor_id"));



ALTER TABLE "public"."buyer_addresses" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "buyer_addresses_owner" ON "public"."buyer_addresses" USING (("auth"."uid"() = "buyer_id")) WITH CHECK (("auth"."uid"() = "buyer_id"));



ALTER TABLE "public"."buyer_bank_accounts" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."cart_items" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."chat_members" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "chat_members_participant_read" ON "public"."chat_members" FOR SELECT USING ((EXISTS ( SELECT 1
   FROM "public"."chats" "c"
  WHERE (("c"."id" = "chat_members"."chat_id") AND (("c"."buyer_id" = "auth"."uid"()) OR ("c"."vendor_id" = "auth"."uid"()))))));



CREATE POLICY "chat_members_self_insert" ON "public"."chat_members" FOR INSERT WITH CHECK ((("user_id" = "auth"."uid"()) AND (EXISTS ( SELECT 1
   FROM "public"."chats" "c"
  WHERE (("c"."id" = "chat_members"."chat_id") AND (("c"."buyer_id" = "auth"."uid"()) OR ("c"."vendor_id" = "auth"."uid"())))))));



CREATE POLICY "chat_members_self_update" ON "public"."chat_members" FOR UPDATE USING (("user_id" = "auth"."uid"()));



ALTER TABLE "public"."chats" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."credit_transactions" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."deliveries" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "deliveries_party_read" ON "public"."deliveries" FOR SELECT USING ((("auth"."uid"() = "buyer_id") OR ("auth"."uid"() = "vendor_id")));



ALTER TABLE "public"."delivery_quotes" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "delivery_quotes_owner" ON "public"."delivery_quotes" FOR SELECT USING ((("auth"."uid"() = "buyer_id") OR ("auth"."uid"() = "vendor_id")));



ALTER TABLE "public"."delivery_tracking" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "delivery_tracking_party_read" ON "public"."delivery_tracking" FOR SELECT USING ((EXISTS ( SELECT 1
   FROM "public"."deliveries" "d"
  WHERE (("d"."id" = "delivery_tracking"."delivery_id") AND (("d"."buyer_id" = "auth"."uid"()) OR ("d"."vendor_id" = "auth"."uid"()))))));



ALTER TABLE "public"."device_tokens" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."disputes" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "disputes_admin_select" ON "public"."disputes" FOR SELECT USING ((EXISTS ( SELECT 1
   FROM "public"."users" "u"
  WHERE (("u"."id" = "auth"."uid"()) AND ("u"."role" = 'admin'::"text")))));



CREATE POLICY "disputes_admin_update" ON "public"."disputes" FOR UPDATE USING ((EXISTS ( SELECT 1
   FROM "public"."users" "u"
  WHERE (("u"."id" = "auth"."uid"()) AND ("u"."role" = 'admin'::"text")))));



ALTER TABLE "public"."messages" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."notifications" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."orders" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."policy_acceptances" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "policy_acceptances_owner_insert" ON "public"."policy_acceptances" FOR INSERT WITH CHECK (("auth"."uid"() = "user_id"));



CREATE POLICY "policy_acceptances_owner_read" ON "public"."policy_acceptances" FOR SELECT USING (("auth"."uid"() = "user_id"));



ALTER TABLE "public"."product_variants" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."products" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."reviews" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."shipbubble_wallet" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."state_change_requests" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."stores" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."transactions" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."users" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."vendor_bank_accounts" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."vendor_charges" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "vendor_charges_owner_read" ON "public"."vendor_charges" FOR SELECT USING (("auth"."uid"() = "vendor_id"));



ALTER TABLE "public"."vendor_locations" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "vendor_locations_owner" ON "public"."vendor_locations" USING (("auth"."uid"() = "vendor_id")) WITH CHECK (("auth"."uid"() = "vendor_id"));



GRANT USAGE ON SCHEMA "public" TO "postgres";
GRANT USAGE ON SCHEMA "public" TO "anon";
GRANT USAGE ON SCHEMA "public" TO "authenticated";
GRANT USAGE ON SCHEMA "public" TO "service_role";



GRANT ALL ON FUNCTION "public"."claim_active_dispute"("p_dispute_id" "uuid", "p_vendor_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."claim_active_dispute"("p_dispute_id" "uuid", "p_vendor_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."claim_active_dispute"("p_dispute_id" "uuid", "p_vendor_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."get_chat_list"("p_user_id" "uuid", "p_role" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."get_chat_list"("p_user_id" "uuid", "p_role" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_chat_list"("p_user_id" "uuid", "p_role" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."get_store_review_stats"("p_store_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."get_store_review_stats"("p_store_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_store_review_stats"("p_store_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."grant_welcome_credit"() TO "anon";
GRANT ALL ON FUNCTION "public"."grant_welcome_credit"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."grant_welcome_credit"() TO "service_role";



GRANT ALL ON FUNCTION "public"."guard_message_columns"() TO "anon";
GRANT ALL ON FUNCTION "public"."guard_message_columns"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."guard_message_columns"() TO "service_role";



GRANT ALL ON FUNCTION "public"."guard_order_columns"() TO "anon";
GRANT ALL ON FUNCTION "public"."guard_order_columns"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."guard_order_columns"() TO "service_role";



GRANT ALL ON FUNCTION "public"."guard_user_columns"() TO "anon";
GRANT ALL ON FUNCTION "public"."guard_user_columns"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."guard_user_columns"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."increment_kays_credit"("p_user_id" "uuid", "p_amount" numeric) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."increment_kays_credit"("p_user_id" "uuid", "p_amount" numeric) TO "service_role";



GRANT ALL ON FUNCTION "public"."is_admin"() TO "anon";
GRANT ALL ON FUNCTION "public"."is_admin"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."is_admin"() TO "service_role";



GRANT ALL ON FUNCTION "public"."is_bank_account_locked"("p_user_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."is_bank_account_locked"("p_user_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."is_bank_account_locked"("p_user_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."mark_chat_read"("p_chat_id" "uuid", "p_user_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."mark_chat_read"("p_chat_id" "uuid", "p_user_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."mark_chat_read"("p_chat_id" "uuid", "p_user_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."rls_auto_enable"() TO "anon";
GRANT ALL ON FUNCTION "public"."rls_auto_enable"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."rls_auto_enable"() TO "service_role";



GRANT ALL ON FUNCTION "public"."set_product_vendor_state"() TO "anon";
GRANT ALL ON FUNCTION "public"."set_product_vendor_state"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."set_product_vendor_state"() TO "service_role";



GRANT ALL ON FUNCTION "public"."spend_kays_credit"("p_user_id" "uuid", "p_amount" numeric) TO "anon";
GRANT ALL ON FUNCTION "public"."spend_kays_credit"("p_user_id" "uuid", "p_amount" numeric) TO "authenticated";
GRANT ALL ON FUNCTION "public"."spend_kays_credit"("p_user_id" "uuid", "p_amount" numeric) TO "service_role";



GRANT ALL ON FUNCTION "public"."touch_chat_member"("p_chat_id" "uuid", "p_kind" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."touch_chat_member"("p_chat_id" "uuid", "p_kind" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."touch_chat_member"("p_chat_id" "uuid", "p_kind" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."update_updated_at"() TO "anon";
GRANT ALL ON FUNCTION "public"."update_updated_at"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."update_updated_at"() TO "service_role";



GRANT ALL ON TABLE "public"."buyer_addresses" TO "anon";
GRANT ALL ON TABLE "public"."buyer_addresses" TO "authenticated";
GRANT ALL ON TABLE "public"."buyer_addresses" TO "service_role";



GRANT ALL ON TABLE "public"."buyer_bank_accounts" TO "anon";
GRANT ALL ON TABLE "public"."buyer_bank_accounts" TO "authenticated";
GRANT ALL ON TABLE "public"."buyer_bank_accounts" TO "service_role";



GRANT ALL ON TABLE "public"."cart_items" TO "anon";
GRANT ALL ON TABLE "public"."cart_items" TO "authenticated";
GRANT ALL ON TABLE "public"."cart_items" TO "service_role";



GRANT ALL ON TABLE "public"."chat_members" TO "anon";
GRANT ALL ON TABLE "public"."chat_members" TO "authenticated";
GRANT ALL ON TABLE "public"."chat_members" TO "service_role";



GRANT ALL ON TABLE "public"."chats" TO "anon";
GRANT ALL ON TABLE "public"."chats" TO "authenticated";
GRANT ALL ON TABLE "public"."chats" TO "service_role";



GRANT ALL ON TABLE "public"."credit_transactions" TO "anon";
GRANT ALL ON TABLE "public"."credit_transactions" TO "authenticated";
GRANT ALL ON TABLE "public"."credit_transactions" TO "service_role";



GRANT ALL ON TABLE "public"."deliveries" TO "anon";
GRANT ALL ON TABLE "public"."deliveries" TO "authenticated";
GRANT ALL ON TABLE "public"."deliveries" TO "service_role";



GRANT ALL ON TABLE "public"."delivery_quotes" TO "anon";
GRANT ALL ON TABLE "public"."delivery_quotes" TO "authenticated";
GRANT ALL ON TABLE "public"."delivery_quotes" TO "service_role";



GRANT ALL ON TABLE "public"."delivery_tracking" TO "anon";
GRANT ALL ON TABLE "public"."delivery_tracking" TO "authenticated";
GRANT ALL ON TABLE "public"."delivery_tracking" TO "service_role";



GRANT ALL ON TABLE "public"."device_tokens" TO "anon";
GRANT ALL ON TABLE "public"."device_tokens" TO "authenticated";
GRANT ALL ON TABLE "public"."device_tokens" TO "service_role";



GRANT ALL ON TABLE "public"."disputes" TO "anon";
GRANT ALL ON TABLE "public"."disputes" TO "authenticated";
GRANT ALL ON TABLE "public"."disputes" TO "service_role";



GRANT ALL ON TABLE "public"."messages" TO "anon";
GRANT ALL ON TABLE "public"."messages" TO "authenticated";
GRANT ALL ON TABLE "public"."messages" TO "service_role";



GRANT ALL ON TABLE "public"."notifications" TO "anon";
GRANT ALL ON TABLE "public"."notifications" TO "authenticated";
GRANT ALL ON TABLE "public"."notifications" TO "service_role";



GRANT ALL ON TABLE "public"."orders" TO "anon";
GRANT ALL ON TABLE "public"."orders" TO "authenticated";
GRANT ALL ON TABLE "public"."orders" TO "service_role";



GRANT ALL ON TABLE "public"."policy_acceptances" TO "anon";
GRANT ALL ON TABLE "public"."policy_acceptances" TO "authenticated";
GRANT ALL ON TABLE "public"."policy_acceptances" TO "service_role";



GRANT ALL ON TABLE "public"."product_variants" TO "anon";
GRANT ALL ON TABLE "public"."product_variants" TO "authenticated";
GRANT ALL ON TABLE "public"."product_variants" TO "service_role";



GRANT ALL ON TABLE "public"."products" TO "anon";
GRANT ALL ON TABLE "public"."products" TO "authenticated";
GRANT ALL ON TABLE "public"."products" TO "service_role";



GRANT ALL ON TABLE "public"."users" TO "anon";
GRANT ALL ON TABLE "public"."users" TO "authenticated";
GRANT ALL ON TABLE "public"."users" TO "service_role";



GRANT ALL ON TABLE "public"."public_profiles" TO "anon";
GRANT ALL ON TABLE "public"."public_profiles" TO "authenticated";
GRANT ALL ON TABLE "public"."public_profiles" TO "service_role";



GRANT ALL ON TABLE "public"."reviews" TO "anon";
GRANT ALL ON TABLE "public"."reviews" TO "authenticated";
GRANT ALL ON TABLE "public"."reviews" TO "service_role";



GRANT ALL ON TABLE "public"."shipbubble_wallet" TO "anon";
GRANT ALL ON TABLE "public"."shipbubble_wallet" TO "authenticated";
GRANT ALL ON TABLE "public"."shipbubble_wallet" TO "service_role";



GRANT ALL ON TABLE "public"."state_change_requests" TO "anon";
GRANT ALL ON TABLE "public"."state_change_requests" TO "authenticated";
GRANT ALL ON TABLE "public"."state_change_requests" TO "service_role";



GRANT ALL ON TABLE "public"."stores" TO "anon";
GRANT ALL ON TABLE "public"."stores" TO "authenticated";
GRANT ALL ON TABLE "public"."stores" TO "service_role";



GRANT ALL ON TABLE "public"."transactions" TO "anon";
GRANT ALL ON TABLE "public"."transactions" TO "authenticated";
GRANT ALL ON TABLE "public"."transactions" TO "service_role";



GRANT ALL ON TABLE "public"."vendor_bank_accounts" TO "anon";
GRANT ALL ON TABLE "public"."vendor_bank_accounts" TO "authenticated";
GRANT ALL ON TABLE "public"."vendor_bank_accounts" TO "service_role";



GRANT ALL ON TABLE "public"."vendor_charges" TO "anon";
GRANT ALL ON TABLE "public"."vendor_charges" TO "authenticated";
GRANT ALL ON TABLE "public"."vendor_charges" TO "service_role";



GRANT ALL ON TABLE "public"."vendor_locations" TO "anon";
GRANT ALL ON TABLE "public"."vendor_locations" TO "authenticated";
GRANT ALL ON TABLE "public"."vendor_locations" TO "service_role";



ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "service_role";






ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "service_role";






ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "service_role";







