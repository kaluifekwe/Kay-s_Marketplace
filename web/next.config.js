/** @type {import('next').NextConfig} */

// Images are plain <img> tags or CSS background-image (the homepage hero).
// Product/store images point only at our Supabase Storage host; blog hero
// images may also come from Unsplash (images.unsplash.com) — see
// lib/format.ts safeImageUrl/safeBlogImageUrl, which drop anything outside
// these hosts before a URL ever reaches here. The homepage hero's own photos
// are fixed marketing content from Pexels (images.pexels.com), hardcoded in
// components/Hero.tsx, not user input.
const supabaseHost = (() => {
  try {
    return new URL(process.env.SUPABASE_URL || "").host;
  } catch {
    return "";
  }
})();

// The site has no user-generated HTML. Forms are a GET search box and the
// waitlist POST (/api/waitlist, same-origin only — see form-action below and
// waitlist_signups.sql for the DB-side guard). 'unsafe-inline' scripts are
// required by Next's own hydration payload; the remaining directives lock
// everything else down.
const csp = [
  "default-src 'self'",
  "script-src 'self' 'unsafe-inline'",
  "style-src 'self' 'unsafe-inline'",
  `img-src 'self' data: https://images.unsplash.com https://images.pexels.com ${supabaseHost ? "https://" + supabaseHost : ""}`.trim(),
  "font-src 'self'",
  "connect-src 'self'",
  "object-src 'none'",
  "base-uri 'self'",
  "form-action 'self'",
  "frame-ancestors 'none'",
  "upgrade-insecure-requests",
].join("; ");

const securityHeaders = [
  { key: "Content-Security-Policy", value: csp },
  { key: "Strict-Transport-Security", value: "max-age=63072000; includeSubDomains; preload" },
  { key: "X-Content-Type-Options", value: "nosniff" },
  { key: "X-Frame-Options", value: "DENY" },
  { key: "Referrer-Policy", value: "strict-origin-when-cross-origin" },
  { key: "Permissions-Policy", value: "camera=(), microphone=(), geolocation=(), payment=(), usb=()" },
  { key: "Cross-Origin-Opener-Policy", value: "same-origin" },
];

const nextConfig = {
  poweredByHeader: false,
  async headers() {
    return [{ source: "/:path*", headers: securityHeaders }];
  },
};

module.exports = nextConfig;
