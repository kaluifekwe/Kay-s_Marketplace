import { APP_NAME, getAppCtaHref } from "@/lib/format";

// Simple landing for the bare domain. Individual products live at /p/[id] and
// stores at /store/[handle].
export default function Home() {
  const cta = getAppCtaHref();
  return (
    <main className="pwrap">
      <div className="card">
        <div className="pbody">
          <h1 className="name">{APP_NAME}</h1>
          <p className="desc">
            The first intrastate online marketplace in Nigeria — shop trusted
            vendors with escrow protection.
          </p>
          {cta ? (
            <a className="cta" href={cta}>
              Get the {APP_NAME} app
            </a>
          ) : (
            <div className="soon">📱 Launching soon on Google Play</div>
          )}
        </div>
      </div>
      <p className="brand">🔒 {APP_NAME} — secured with escrow protection</p>
    </main>
  );
}
