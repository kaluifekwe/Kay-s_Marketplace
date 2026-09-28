"use client";

import { useEffect, useState } from "react";
import { APP_NAME } from "@/lib/format";

type Slide = {
  tag: string;
  title: string;
  sub: string;
  bg: string;
  icon: "escrow" | "delivery" | "verified";
};

const SLIDES: Slide[] = [
  {
    tag: "ESCROW PROTECTION",
    title: "Shop safe. Pay with escrow.",
    sub: "Your money only reaches the vendor after you confirm delivery. No confirmation, no release, full refund.",
    bg: "linear-gradient(120deg, #166534, #14532d)",
    icon: "escrow",
  },
  {
    tag: "INTRASTATE DELIVERY",
    title: "Same-day delivery, same state.",
    sub: "Vendors and riders in your own state means faster drop-offs and lower delivery fees.",
    bg: "linear-gradient(120deg, #0f766e, #134e4a)",
    icon: "delivery",
  },
  {
    tag: "TRUST",
    title: "Every vendor, ID-verified.",
    sub: "We check identity before anyone can list a product, so you know who you're buying from.",
    bg: "linear-gradient(120deg, #15803d, #052e16)",
    icon: "verified",
  },
];

const ICONS: Record<Slide["icon"], React.ReactNode> = {
  escrow: (
    <path d="M12 2l8 4v6c0 5-3.5 8-8 10-4.5-2-8-5-8-10V6l8-4z" />
  ),
  delivery: (
    <>
      <rect x="1" y="3" width="15" height="13" />
      <path d="M16 8h4l3 3v5h-7V8z" />
      <circle cx="5.5" cy="18.5" r="2.5" />
      <circle cx="18.5" cy="18.5" r="2.5" />
    </>
  ),
  verified: (
    <>
      <path d="M9 12l2 2 4-4" />
      <path d="M12 3l8 4v5c0 5-3.5 8-8 9-4.5-1-8-4-8-9V7l8-4z" />
    </>
  ),
};

/** Auto-rotating hero banner. Content is fixed marketing copy (not from the
 * database); the CTA link is passed in from the server component that knows
 * the app-store URL, since this client component can't read server env. */
export function Hero({ ctaHref }: { ctaHref: string | null }) {
  const [active, setActive] = useState(0);

  useEffect(() => {
    const id = setInterval(() => setActive((n) => (n + 1) % SLIDES.length), 6000);
    return () => clearInterval(id);
  }, []);

  const slide = SLIDES[active];

  return (
    <div className="hero" style={{ background: slide.bg }}>
      <div className="heroInner">
        <div className="heroText">
          <span className="heroTag">{slide.tag}</span>
          <h1 className="heroTitle">{slide.title}</h1>
          <p className="heroSub">{slide.sub}</p>
          {ctaHref ? (
            <a className="heroCta" href={ctaHref} rel="noopener">
              Get the {APP_NAME} app
            </a>
          ) : (
            <span className="heroCta heroCtaSoon">Launching soon on Google Play</span>
          )}
        </div>
        <div className="heroArt" aria-hidden="true">
          <svg width="72" height="72" viewBox="0 0 24 24" fill="none" stroke="#fff" strokeWidth="1.4" strokeLinecap="round" strokeLinejoin="round" opacity="0.9">
            {ICONS[slide.icon]}
          </svg>
        </div>
      </div>
      <div className="heroDots" role="tablist" aria-label="Homepage highlights">
        {SLIDES.map((s, i) => (
          <button
            key={s.tag}
            type="button"
            role="tab"
            aria-selected={i === active}
            aria-label={s.tag}
            className={i === active ? "heroDot on" : "heroDot"}
            onClick={() => setActive(i)}
          />
        ))}
      </div>
    </div>
  );
}
