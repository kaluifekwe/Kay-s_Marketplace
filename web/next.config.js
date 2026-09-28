/** @type {import('next').NextConfig} */

// Images are plain <img> tags pointing at our Supabase Storage host only, and
// lib/format.ts drops any other host, so the CSP can allow just that host.
const supabaseHost = (() => {
  try {
    return new URL(process.env.SUPABASE_URL || "").host;
  } catch {
    return "";
  }
})();

// The site has no user-generated HTML and no forms besides a GET search box.
// 'unsafe-inline' scripts are required by Next's own hydration payload; the
// remaining directives lock everything else down.
const csp = [
  "default-src 'self'",
  "script-src 'self' 'unsafe-inline'",
  "style-src 'self' 'unsafe-inline'",
  `img-src 'self' data: ${supabaseHost ? "https://" + supabaseHost : ""}`.trim(),
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
