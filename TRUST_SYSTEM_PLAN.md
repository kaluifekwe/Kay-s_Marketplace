# DispatchPH Trust & Fraud Prevention System
## Designed for Nigerian E-commerce

---

## The Core Problem
Nigerian online marketplace fraud comes from both sides:
- **Buyer fraud**: Get item + get refund = double dipping
- **Buyer ghosting**: Receive item, never confirm, vendor payment stuck
- **Vendor fraud**: Ship wrong/defective item, blame logistics
- **Fake disputes**: Both sides may lie, no evidence chain

---

## Solution Architecture

### 1. EVIDENCE-BASED DELIVERY SYSTEM

#### When Vendor Ships:
```
Vendor clicks "Mark as Shipped"
  → Must enter: Rider name, Rider phone, Delivery method
  → Optional: Upload photo of packaged item before shipping
  → This creates a delivery record that can't be disputed
```

#### When Buyer Receives:
```
Buyer sees "Confirm Delivery" button
  → MUST upload photo of received item (mandatory, not optional)
  → Photo is stored in Supabase Storage with timestamp
  → Confirmation only completes with photo attached
  → This proves buyer actually received the physical item
```

#### Auto-Release Protection:
```
If buyer doesn't confirm within 24 hours:
  → Timer shows countdown on buyer's order screen
  → At 0:00 → payment auto-releases to vendor
  → Buyer CANNOT request refund after auto-release
  → Only exception: platform admin override (future)
```

### 2. EVIDENCE-BASED REFUND SYSTEM

#### Requesting a Refund:
```
Buyer clicks "Request Refund"
  → Step 1: Select issue type (dropdown):
     • Wrong item received
     • Item damaged in transit
     • Item not as described
     • Item not received at all
     • Other
  → Step 2: Write detailed explanation (required)
  → Step 3: Upload photo evidence (required, min 1, max 5)
     • Photo of the issue
     • Photo of packaging
     • Photo of item details/labels
  → Step 4: Submit → 48-hour resolution window starts
```

#### Vendor Counter-Evidence:
```
Vendor receives refund request
  → Sees buyer's evidence photos + explanation
  → Can upload counter-evidence:
     • Photo of item before shipping
     • Photo of packaging with buyer's name/address
     • Delivery rider's confirmation
  → Can write response explaining situation
  → Can offer: replacement, partial refund, or full refund
```

#### Resolution Window (48 hours):
```
Hour 0-24: Both parties present evidence
Hour 24-48: Negotiation period
  → Buyer can accept/reject vendor's offer
  → Vendor can accept/reject buyer's demand
  → Both can message each other in-app
Hour 48: If unresolved → ESCALATED to platform admin
  → All evidence is preserved
  → Admin reviews and makes final decision
```

### 3. DELIVERY RIDER INTEGRATION

#### Rider Confirmation (Phase 5):
```
When rider delivers:
  → Rider confirms delivery in app
  → Rider takes photo of delivery location
  → GPS location recorded
  → This creates a third-party confirmation
  → Both buyer and vendor can see rider's proof
```

#### Why This Matters:
- Rider is neutral third party
- GPS proves location
- Photo proves delivery happened
- Buyer can't claim "never received" when rider has proof

### 4. BUYER TRUST SCORE

#### Track Every Buyer's History:
```
Trust Score = 100 (starting)
  - Each approved refund: -10 points
  - Each rejected refund (fraud attempt): -25 points
  - Each successful purchase (no issues): +2 points
  - Each on-time confirmation: +1 point

Score thresholds:
  90-100: "Trusted Buyer" (green badge)
  70-89:  "Regular Buyer" (normal)
  50-69:  "Watched Buyer" (orange warning)
  Below 50: "Restricted" (can only COD, no escrow)
```

#### What Trust Score Controls:
- Trusted buyers: Faster auto-release (12h instead of 24h)
- Low-score buyers: Vendor can refuse the order
- Repeat offenders: Account suspended after 3 fraud flags

### 5. VENDOR PROTECTION RULES

#### Vendor Can Dispute If:
- Buyer has low trust score
- Buyer's evidence photos are blurry/fake
- Delivery rider confirms delivery
- Buyer waited past 24h auto-release window
- Buyer's claim contradicts evidence

#### Vendor Must Follow:
- Ship within 48h of order or auto-cancel
- Provide rider details when shipping
- Must respond to disputes within 24h
- Can't block buyer communication during dispute

### 6. NIGERIAN-SPECIFIC FEATURES

#### Phone Verification:
- Both buyer and vendor must verify phone number
- Phone number displayed during disputes (for direct call)
- WhatsApp-style communication + in-app chat

#### Delivery Address Proof:
- Buyer's delivery address saved in profile
- Rider delivers to saved address only
- Address changes require re-verification

#### Payment Trust:
- Escrow holds payment until confirmed
- Bank details verified during vendor onboarding
- Payout only to verified bank accounts (Phase 4)

---

## Implementation Priority

### Phase 1 (Current):
- [x] Basic escrow with auto-release timer
- [x] Refund request with reason
- [x] Vendor dispute response
- [x] Replacement product offering

### Phase 2 (Next - Build Now):
- [ ] Photo evidence required for delivery confirmation
- [ ] Photo evidence required for refund requests
- [ ] Vendor counter-evidence upload
- [ ] 48-hour resolution window with countdown
- [ ] Issue type categorization

### Phase 3 (Soon):
- [ ] Buyer trust score tracking
- [ ] Vendor trust score tracking
- [ ] Serial refund flagging
- [ ] Auto-cancel if vendor doesn't ship in 48h

### Phase 4 (Payments):
- [ ] Real payment integration (Paystack/Flutterwave)
- [ ] Bank account verification
- [ ] Automated payouts

### Phase 5 (Logistics):
- [ ] Delivery rider app
- [ ] GPS tracking
- [ ] Rider photo confirmation
- [ ] Third-party delivery proof

### Phase 6 (Admin):
- [ ] Admin dashboard for dispute resolution
- [ ] Evidence review panel
- [ ] Account suspension tools
- [ ] Analytics and reporting

---

## Database Changes Needed

### Orders Table:
- `rider_name` text
- `rider_phone` text
- `delivery_method` text
- `shipping_proof_url` text (vendor's photo before shipping)
- `delivery_photo_url` text (buyer's confirmation photo)

### Disputes Table:
- `evidence_urls` text (JSON array of photos)
- `issue_type` text (wrong_item, damaged, not_as_described, not_received, other)
- `vendor_evidence_urls` text (JSON array of counter-evidence)
- `resolution_deadline` timestamptz (48h from creation)
- `escalated_to_admin` boolean

### Users Table:
- `trust_score` integer (default 100)
- `phone_verified` boolean
- `total_refunds` integer
- `total_purchases` integer

---

## Key Rules to Display in App

### Buyer Agreement (shown during signup):
1. "I understand that confirming delivery requires photo evidence"
2. "I understand that false refund requests may result in account restriction"
3. "I agree to the 48-hour dispute resolution window"
4. "I understand that auto-release happens after 24 hours of delivery"

### Vendor Agreement:
1. "I agree to ship within 48 hours or order auto-cancels"
2. "I must provide rider details when shipping"
3. "I must respond to disputes within 24 hours"
4. "I understand that I cannot block buyer communication during disputes"
