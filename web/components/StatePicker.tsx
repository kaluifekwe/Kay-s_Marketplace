import Link from "next/link";
import { listStateVendorCounts } from "@/lib/data";
import { slugify } from "@/lib/validate";

/** "Shop by state" — the one section on this homepage that has no Temu
 * equivalent, since Temu isn't intrastate. Only states with at least one
 * verified vendor are shown (real counts, not the full 37-state list). */
export async function StatePicker() {
  const counts = await listStateVendorCounts();
  if (!counts.length) return null;
  const top = counts.slice(0, 6);

  return (
    <section className="section" id="shop-by-state" aria-label="Shop by state">
      <div className="sectionHead">
        <h2 className="sectionTitle">Shop by state</h2>
        <span className="sectionHint">We&#39;re intrastate — pick yours for the fastest delivery</span>
      </div>
      <div className="stateGrid">
        {top.map((s) => (
          <Link key={s.state} href={`/state/${slugify(s.state)}`} className="stateCard">
            <div className="stateName">{s.state}</div>
            <div className="stateCount">
              {s.count} {s.count === 1 ? "vendor" : "vendors"} nearby
            </div>
          </Link>
        ))}
      </div>
    </section>
  );
}
