import Link from "next/link";
import { getFeaturedStore } from "@/lib/data";

/** Homepage "vendor spotlight" band. Only ever shows a real, rated store —
 * returns nothing rather than a fabricated trust signal when no store has
 * reviews yet. */
export async function FeaturedVendor() {
  const store = await getFeaturedStore();
  if (!store) return null;

  return (
    <div style={{ maxWidth: 1240, margin: "28px auto 0", padding: "0 24px", width: "100%" }}>
      <Link href={`/store/${store.handle}`} className="vendorBanner">
        <svg width="26" height="26" viewBox="0 0 24 24" fill="none" stroke="#92400e" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
          <path d="M11 2H9v3H4v2h1l1 12a2 2 0 0 0 2 2h8a2 2 0 0 0 2-2l1-12h1V5h-5V2h-2z" />
        </svg>
        <div className="vendorText">
          <div className="vendorTitle">
            Vendor spotlight — {store.name}
            {store.is_verified ? " ✔" : ""}
          </div>
          <div className="vendorSub">
            {Number(store.avg_rating).toFixed(1)}★ rating · {store.review_count}{" "}
            {store.review_count === 1 ? "review" : "reviews"}
            {store.state ? ` · ${store.state}` : ""}
          </div>
        </div>
        <span className="vendorGo">View store</span>
      </Link>
    </div>
  );
}
