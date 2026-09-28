const ITEMS: { title: string; sub: string; icon: React.ReactNode }[] = [
  {
    title: "Escrow protected",
    sub: "Money held safe until you confirm",
    icon: <path d="M12 2l8 4v6c0 5-3.5 8-8 10-4.5-2-8-5-8-10V6l8-4z" />,
  },
  {
    title: "Verified vendors",
    sub: "ID-checked before they can sell",
    icon: (
      <>
        <path d="M9 12l2 2 4-4" />
        <path d="M12 3l8 4v5c0 5-3.5 8-8 9-4.5-1-8-4-8-9V7l8-4z" />
      </>
    ),
  },
  {
    title: "Fast local delivery",
    sub: "Same state, same-day where possible",
    icon: (
      <>
        <rect x="1" y="3" width="15" height="13" />
        <path d="M16 8h4l3 3v5h-7V8z" />
        <circle cx="5.5" cy="18.5" r="2.5" />
        <circle cx="18.5" cy="18.5" r="2.5" />
      </>
    ),
  },
];

export function TrustStrip() {
  return (
    <div className="trustStrip">
      {ITEMS.map((it, i) => (
        <div className="trustItem" key={it.title} style={i > 0 ? { borderLeft: "1px solid #e5e7eb" } : undefined}>
          <div className="trustIcon">
            <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="var(--green)" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
              {it.icon}
            </svg>
          </div>
          <div>
            <div className="trustTitle">{it.title}</div>
            <div className="trustSub">{it.sub}</div>
          </div>
        </div>
      ))}
    </div>
  );
}
