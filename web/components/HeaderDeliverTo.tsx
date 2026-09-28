"use client";

import { useRouter } from "next/navigation";
import { STATES, slugify } from "@/lib/validate";

/** Small client component: a native select that navigates to /state/[x].
 * The only interactivity in the header, kept isolated so SiteHeader itself
 * can stay a plain (fetching) server component. */
export function HeaderDeliverTo() {
  const router = useRouter();
  return (
    <label className="deliverTo">
      <svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="var(--green)" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
        <path d="M21 10c0 7-9 13-9 13s-9-6-9-13a9 9 0 0 1 18 0z" />
        <circle cx="12" cy="10" r="3" />
      </svg>
      <select
        aria-label="Deliver to state"
        defaultValue=""
        onChange={(e) => {
          if (e.target.value) router.push(`/state/${e.target.value}`);
        }}
      >
        <option value="" disabled>
          Deliver to…
        </option>
        {STATES.map((s) => (
          <option key={s} value={slugify(s)}>
            {s}
          </option>
        ))}
      </select>
    </label>
  );
}
