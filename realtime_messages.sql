-- Chat realtime fix.
--
-- Symptom: while a chat is open, neither party sees new messages live — they
-- only appear after leaving and re-entering the chat. Typing indicators and
-- read ticks DO work.
--
-- Cause: the `messages` table was never added to the `supabase_realtime`
-- publication (only `chat_members` and `orders` were). Postgres change events
-- for messages (INSERT of new messages, UPDATE of read_at / delivery_fee_status)
-- are therefore never broadcast. Typing works because it rides realtime
-- *broadcast*; read ticks work because they key off the published `chat_members`
-- markers — but the message rows themselves are silent.
--
-- Safe to run multiple times.

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_publication_tables
    WHERE pubname = 'supabase_realtime'
      AND schemaname = 'public'
      AND tablename = 'messages'
  ) THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.messages;
  END IF;
END $$;

-- Ensure UPDATE/DELETE realtime payloads carry the full row (needed for
-- RLS-filtered realtime to evaluate the row against each subscriber).
ALTER TABLE public.messages REPLICA IDENTITY FULL;
