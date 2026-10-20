# Kay's Market — Google Play Store Listing

Copy-paste these into the Play Console when you set up the store listing.

---

## App name (max 30 chars)
```
Kay's Market
```

## Short description (max 80 chars)
```
Buy & sell safely in Nigeria: escrow protection, chat, verified users, delivery
```

## Full description (max 4000 chars)
```
Kay's Market is Nigeria's trusted marketplace for buying and selling — with your money protected every step of the way.

Shop from local vendors or open your own store, chat directly to agree on the details, and pay safely through escrow: your money is only released to the seller once your order is delivered and confirmed. No more "pay first and pray."

WHY KAY'S MARKET?

🛡️ Escrow protection
Your payment is held securely and only released to the vendor after you receive your order. Buy with confidence.

✅ Verified users
Every buyer and vendor verifies their identity with their NIN, so you're dealing with real people — not fake accounts.

💬 In-app chat
Message vendors directly to ask questions, see product photos and videos, and agree on price and delivery before you pay.

🚚 Built-in delivery
Get your orders delivered through trusted courier partners, with delivery fees agreed right inside the chat.

👛 Wallet
Fund your wallet, pay in seconds, and withdraw to your bank anytime.

⚖️ Dispute resolution
If something isn't right, our dispute process helps you and the vendor reach a fair outcome — your money stays protected until it's sorted.

🏪 Sell with ease
Open a store in minutes, list your products with photos, chat with buyers, and get paid safely into your wallet.

HOW IT WORKS
1. Browse products or search for what you need.
2. Chat with the vendor and agree on price and delivery.
3. Pay securely — your money is held in escrow.
4. Receive your order and confirm.
5. The vendor gets paid. Everyone wins.

Whether you're buying everyday items or growing your business as a vendor, Kay's Market makes local commerce safe, simple and fair.

Download Kay's Market and start buying and selling with confidence.
```

---

## Graphics you need to prepare

| Asset | Size / format | Notes |
|---|---|---|
| App icon | 512 × 512 PNG (32-bit) | Your logo on a solid background; no rounded corners (Play adds them) |
| Feature graphic | 1024 × 500 PNG/JPG | Banner shown at the top of the listing; put the logo + a short tagline |
| Phone screenshots | 2–8 images, PNG/JPG, e.g. 1080 × 1920 (9:16) | Real screens: home/marketplace, product, chat, escrow/checkout, wallet |
| (Optional) Tablet screenshots | — | Not required for phone-only launch |

Tip: screenshots with a short caption band ("Pay safely with escrow", "Chat before you buy") convert better, but plain screenshots are fine to start.

---

## Data Safety form — answers mapped to what the app actually does

Mark these as **Collected**. Under Play's rules, transfers to providers that process **on your behalf** (Supabase, Prembly, Flutterwave, Paystack, Shipbubble, Terminal, Firebase) are generally **NOT** counted as "Shared" — so answer "Shared: No" for these unless a provider uses the data for its own purposes.

| Data type | Collected | Purpose |
|---|---|---|
| Name | Yes | Account management, App functionality (orders/delivery) |
| Email address | Yes | Account management |
| Phone number | Yes | App functionality, delivery |
| Address | Yes | App functionality (delivery) |
| Other info — National ID (NIN) | Yes | Fraud prevention, identity verification |
| User payment info / bank details | Yes | App functionality (payments, payouts) |
| Purchase history | Yes | App functionality |
| Photos and videos | Yes | App functionality (chat, product listings) |
| In-app messages | Yes | App functionality (buyer–vendor chat) |
| App interactions | Yes | App functionality |
| Crash logs / diagnostics | Yes | App functionality (stability) |
| Device or other IDs (push token) | Yes | App functionality (notifications) |

**Security section:**
- Is data encrypted in transit? **Yes**
- Can users request that data be deleted? **Yes** → deletion URL: `https://kaysmarket-legal.web.app/delete-account`
- Do you have a way to delete in-app? **Yes** (Settings → Delete Account)

## Other required listing fields
- **Privacy Policy URL:** `https://kaysmarket-legal.web.app/privacy`
- **App category:** Shopping
- **Tags:** marketplace, shopping, ecommerce
- **Content rating:** complete the questionnaire (a marketplace with chat is typically rated Teen/PEGI 12 — answer honestly re: user communication)
- **Target audience:** 18+ (you require NIN + handle payments)
- **Contact email:** kaluifekwe6@gmail.com (or your support address once set up)
