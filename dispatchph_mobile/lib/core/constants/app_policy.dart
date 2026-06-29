/// The Buyer & Vendor Agreement shown at the policy-acceptance gate and in the
/// "Terms & Policy" section of each profile.
///
/// Bump [kPolicyVersion] whenever the wording materially changes — every
/// login/registration path routes through the gate, which re-prompts any user
/// who has not accepted the current version. Keep this in sync with
/// docs/policy.md (the human-readable source) and the policy_acceptances table.
const String kPolicyVersion = '1.0';

const String kPolicyTitle = "Kay's Marketplace — Buyer & Vendor Agreement";

const String kPolicyEffective = 'Version 1.0';

const String kPolicyIntro =
    "By tapping “I Agree”, you confirm you have read and accepted this "
    "agreement. We'll ask you to accept again when we make important changes.";

const String kPolicyClosing =
    "By tapping “I Agree”, you confirm you have read, understood, and "
    "accepted this agreement.";

/// One block of the agreement: an optional heading, an optional intro
/// paragraph, and zero or more bullet points. Rendered by [PolicyBody].
class PolicyBlock {
  final String? heading;
  final String? body;
  final List<String> bullets;

  const PolicyBlock({this.heading, this.body, this.bullets = const []});
}

const List<PolicyBlock> kPolicyBlocks = [
  PolicyBlock(
    heading: 'The basics',
    body:
        "Kay's Marketplace connects buyers and vendors. Vendors sell the items; "
        "we hold the buyer's payment in escrow and only release it to the vendor "
        "after delivery is confirmed.",
  ),
  PolicyBlock(
    heading: 'For everyone',
    bullets: [
      'Escrow — We hold your payment; the vendor is paid only after delivery is confirmed.',
      'Delivery — At checkout you pick a courier and pay the exact fee. If no courier covers the route, you and the vendor agree on delivery in chat.',
      'Confirming delivery — You have 24 hours after delivery to confirm or report a problem; otherwise the order completes and the vendor is paid.',
      "Price changes — If a courier's price rises before pickup, we cover it — you're never charged extra.",
    ],
  ),
  PolicyBlock(
    heading: 'Refunds (buyer protection)',
    bullets: [
      'Not delivered or not received — full refund (item price and delivery fee).',
      'Problem with a delivered item — item price refunded, delivery fee is not, after our team reviews the case.',
      "Refunds go to Kay's Credit by default, or your original payment method where applicable.",
    ],
  ),
  PolicyBlock(
    heading: 'For vendors',
    bullets: [
      'Getting paid — You are paid after the buyer confirms delivery, or after the 24-hour window. On courier orders you receive the item price only — the delivery fee pays the courier.',
      'Request Pickup (24-hour deadline) — Prepare the package and tap Request Pickup so we can book the courier. You have 24 hours from payment (we remind you at 12 hours left). Miss it, and the order is auto-cancelled and the buyer fully refunded.',
      'Only request pickup when ready — If a courier is sent and there is no package to collect, the wasted courier fee is charged to you and deducted from your next payout.',
      "Play fair — List items accurately, fulfil orders you accept, and don't game the escrow, refund, or delivery systems. Abuse may lead to charges, suspension, or removal.",
    ],
  ),
  PolicyBlock(
    heading: 'Changes',
    body:
        "We may update these terms. When we do, you'll be asked to read and "
        "accept the new version before continuing.",
  ),
];
