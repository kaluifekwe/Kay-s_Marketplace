-- Fix RLS policies for DispatchPH

-- Drop old policies
drop policy if exists "Chats buyer insert" on chats;
drop policy if exists "Chats buyer read" on chats;
drop policy if exists "Chats vendor read" on chats;
drop policy if exists "Chats read" on chats;
drop policy if exists "Chats insert" on chats;
drop policy if exists "Messages read" on messages;
drop policy if exists "Messages insert" on messages;
drop policy if exists "Messages update" on messages;
drop policy if exists "Users read own" on users;

-- Chats: both buyer and vendor can read and insert
create policy "Chats read" on chats for select
  using (auth.uid() = buyer_id or auth.uid() = vendor_id);
create policy "Chats insert" on chats for insert
  with check (auth.uid() = buyer_id or auth.uid() = vendor_id);

-- Messages: participants can read, sender can insert
create policy "Messages read" on messages for select
  using (chat_id in (
    select id from chats where buyer_id = auth.uid() or vendor_id = auth.uid()
  ));
create policy "Messages insert" on messages for insert
  with check (auth.uid() = sender_id);
create policy "Messages update" on messages for update
  using (chat_id in (
    select id from chats where buyer_id = auth.uid() or vendor_id = auth.uid()
  ));

-- Users: any auth user can read (for chat names)
drop policy if exists "Users read others" on users;
create policy "Users read own" on users for select using (auth.uid() = id);
create policy "Users read others" on users for select using (true);
