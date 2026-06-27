-- DispatchPH Marketplace Schema for Supabase

-- Enable UUID extension
create extension if not exists "uuid-ossp";

-- ===================== USERS =====================
create table users (
  id uuid primary key default uuid_generate_v4(),
  email text unique not null,
  password text not null,
  name text not null,
  role text not null check (role in ('buyer', 'vendor', 'rider')),
  phone text,
  nin text,
  store_id uuid,
  created_at timestamptz not null default now(),
  last_active timestamptz
);

-- ===================== STORES =====================
create table stores (
  id uuid primary key default uuid_generate_v4(),
  vendor_id uuid not null references users(id) on delete cascade,
  name text not null,
  description text,
  logo_path text,
  address text,
  phone text,
  created_at timestamptz not null default now()
);

alter table users add constraint fk_users_store
  foreign key (store_id) references stores(id) on delete set null;

-- ===================== PRODUCTS =====================
create table products (
  id uuid primary key default uuid_generate_v4(),
  store_id uuid not null references stores(id) on delete cascade,
  name text not null,
  description text,
  price real not null,
  images text not null default '[]',
  category text,
  stock integer not null default 0,
  created_at timestamptz not null default now()
);

-- ===================== CART ITEMS =====================
create table cart_items (
  id uuid primary key default uuid_generate_v4(),
  buyer_id uuid not null references users(id) on delete cascade,
  product_id uuid not null references products(id) on delete cascade,
  quantity integer not null default 1,
  added_at timestamptz not null default now()
);

-- ===================== ORDERS =====================
create table orders (
  id uuid primary key default uuid_generate_v4(),
  buyer_id uuid not null references users(id) on delete cascade,
  vendor_id uuid not null references users(id) on delete cascade,
  store_id uuid not null references stores(id) on delete cascade,
  items text not null default '[]',
  total real not null,
  status text not null default 'paid'
    check (status in ('paid', 'shipped', 'delivered', 'confirmed', 'refund_requested', 'refunded', 'auto_released')),
  shipping_method text,
  tracking_ref text,
  paid_at timestamptz,
  shipped_at timestamptz,
  delivered_at timestamptz,
  confirmed_at timestamptz,
  auto_release_at timestamptz,
  created_at timestamptz not null default now()
);

-- ===================== CHATS =====================
create table chats (
  id uuid primary key default uuid_generate_v4(),
  order_id text not null,
  buyer_id uuid not null references users(id) on delete cascade,
  vendor_id uuid not null references users(id) on delete cascade,
  created_at timestamptz not null default now()
);

-- ===================== MESSAGES =====================
create table messages (
  id uuid primary key default uuid_generate_v4(),
  chat_id uuid not null references chats(id) on delete cascade,
  sender_id uuid not null references users(id) on delete cascade,
  sender_role text not null check (sender_role in ('buyer', 'vendor', 'rider')),
  content text not null,
  type text not null default 'text' check (type in ('text', 'image', 'video', 'product_card')),
  reply_to_id uuid references messages(id) on delete set null,
  reply_to_content text,
  reply_to_sender text,
  read_at timestamptz,
  created_at timestamptz not null default now()
);

-- ===================== DISPUTES =====================
create table disputes (
  id uuid primary key default uuid_generate_v4(),
  order_id uuid not null references orders(id) on delete cascade,
  raised_by uuid not null references users(id) on delete cascade,
  reason text not null,
  status text not null default 'open' check (status in ('open', 'resolved', 'rejected')),
  resolved_at timestamptz,
  created_at timestamptz not null default now()
);

-- ===================== INDEXES =====================
create index idx_products_store_id on products(store_id);
create index idx_products_category on products(category);
create index idx_cart_items_buyer_id on cart_items(buyer_id);
create index idx_orders_buyer_id on orders(buyer_id);
create index idx_orders_vendor_id on orders(vendor_id);
create index idx_orders_store_id on orders(store_id);
create index idx_chats_buyer_id on chats(buyer_id);
create index idx_chats_vendor_id on chats(vendor_id);
create index idx_chats_order_id on chats(order_id);
create index idx_messages_chat_id on messages(chat_id);
create index idx_messages_created_at on messages(created_at);
create index idx_disputes_order_id on disputes(order_id);

-- ===================== ROW LEVEL SECURITY =====================
alter table users enable row level security;
alter table stores enable row level security;
alter table products enable row level security;
alter table cart_items enable row level security;
alter table orders enable row level security;
alter table chats enable row level security;
alter table messages enable row level security;
alter table disputes enable row level security;

-- ===================== DROP OLD POLICIES IF EXISTING =====================
do $$ begin
  drop policy if exists "Users read own" on users;
  drop policy if exists "Users update own" on users;
  drop policy if exists "Users insert" on users;
  drop policy if exists "Stores public read" on stores;
  drop policy if exists "Stores owner update" on stores;
  drop policy if exists "Stores owner insert" on stores;
  drop policy if exists "Products public read" on products;
  drop policy if exists "Products owner insert" on products;
  drop policy if exists "Products owner update" on products;
  drop policy if exists "Products owner delete" on products;
  drop policy if exists "Cart owner read" on cart_items;
  drop policy if exists "Cart owner insert" on cart_items;
  drop policy if exists "Cart owner delete" on cart_items;
  drop policy if exists "Orders buyer read" on orders;
  drop policy if exists "Orders vendor read" on orders;
  drop policy if exists "Orders buyer insert" on orders;
  drop policy if exists "Orders vendor update" on orders;
  drop policy if exists "Chats buyer read" on chats;
  drop policy if exists "Chats vendor read" on chats;
  drop policy if exists "Chats buyer insert" on chats;
  drop policy if exists "Chats insert" on chats;
  drop policy if exists "Messages read" on messages;
  drop policy if exists "Messages insert" on messages;
  drop policy if exists "Messages update" on messages;
  drop policy if exists "Disputes read" on disputes;
  drop policy if exists "Disputes insert" on disputes;
exception when others then null;
end $$;

-- Users: can read own profile, update own profile; any auth user can read others for chat display
create policy "Users read own" on users for select using (auth.uid() = id);
create policy "Users read others" on users for select using (true);
create policy "Users update own" on users for update using (auth.uid() = id);
create policy "Users insert" on users for insert with check (auth.uid() = id);

-- Stores: anyone can read, only owner can update
create policy "Stores public read" on stores for select using (true);
create policy "Stores owner update" on stores for update using (auth.uid() = vendor_id);
create policy "Stores owner insert" on stores for insert with check (auth.uid() = vendor_id);

-- Products: anyone can read, store owner can CRUD
create policy "Products public read" on products for select using (true);
create policy "Products owner insert" on products for insert
  with check (store_id in (select id from stores where vendor_id = auth.uid()));
create policy "Products owner update" on products for update
  using (store_id in (select id from stores where vendor_id = auth.uid()));
create policy "Products owner delete" on products for delete
  using (store_id in (select id from stores where vendor_id = auth.uid()));

-- Cart: only owner can manage
create policy "Cart owner read" on cart_items for select using (auth.uid() = buyer_id);
create policy "Cart owner insert" on cart_items for insert with check (auth.uid() = buyer_id);
create policy "Cart owner delete" on cart_items for delete using (auth.uid() = buyer_id);

-- Orders: buyer and vendor can see their orders
create policy "Orders buyer read" on orders for select using (auth.uid() = buyer_id);
create policy "Orders vendor read" on orders for select using (auth.uid() = vendor_id);
create policy "Orders buyer insert" on orders for insert with check (auth.uid() = buyer_id);
create policy "Orders vendor update" on orders for update using (auth.uid() = vendor_id);

-- Chats: buyer and vendor can read; both can insert (for product contact flows)
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

-- Disputes: involved parties can read
create policy "Disputes read" on disputes for select
  using (auth.uid() = raised_by or auth.uid() in (
    select buyer_id from orders where id = order_id
    union select vendor_id from orders where id = order_id
  ));
create policy "Disputes insert" on disputes for insert
  with check (auth.uid() = raised_by);
