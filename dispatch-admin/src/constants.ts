// Explicit users column list that OMITS the `password` column, so a password
// hash is never sent to the browser. Use this for every users query / embed.
export const USER_SELECT =
  "id,name,email,role,phone,nin,store_id,unique_id,kays_credit,state,lga,address," +
  "dispute_strikes_count,dispute_flagged,active_dispute_id," +
  "payout_blocked,payout_blocked_reason,payout_blocked_amount,created_at,last_active";

// Safe subset for embedding a related user (buyer/vendor) into another record.
export const USER_EMBED = "id,name,email";
