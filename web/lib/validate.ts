// Strict validation for every value that comes from a URL. Anything that does
// not match is rejected BEFORE it reaches the database. No raw SQL or
// string-built filters anywhere in this app: only supabase-js single-column
// filters with validated values.

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const HANDLE_RE = /^[a-z0-9](?:[a-z0-9-]{0,58}[a-z0-9])?$/;

export const PAGE_SIZE = 24;
export const MAX_PAGE = 20; // caps how deep anyone can crawl one listing

export function isUuid(v: unknown): v is string {
  return typeof v === "string" && UUID_RE.test(v);
}

export function isHandle(v: unknown): v is string {
  return typeof v === "string" && HANDLE_RE.test(v);
}

/** Nigerian states (+ FCT). Used as an allowlist for the state filter. */
export const STATES = [
  "Abia", "Adamawa", "Akwa Ibom", "Anambra", "Bauchi", "Bayelsa", "Benue",
  "Borno", "Cross River", "Delta", "Ebonyi", "Edo", "Ekiti", "Enugu", "FCT",
  "Gombe", "Imo", "Jigawa", "Kaduna", "Kano", "Katsina", "Kebbi", "Kogi",
  "Kwara", "Lagos", "Nasarawa", "Niger", "Ogun", "Ondo", "Osun", "Oyo",
  "Plateau", "Rivers", "Sokoto", "Taraba", "Yobe", "Zamfara",
] as const;

export function slugify(s: string): string {
  return s
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-+|-+$/g, "");
}

/** Match a URL segment/param to a known state (case/spacing-insensitive). */
export function parseState(v: unknown): string | null {
  if (typeof v !== "string") return null;
  const want = slugify(v);
  return STATES.find((s) => slugify(s) === want) ?? null;
}

/**
 * Search text: letters, digits, spaces, and a few harmless marks only, max 60
 * chars. The result is never placed in a filter STRING (like .or("a.ilike.%x%"),
 * which can be injected with commas/parentheses); it is only passed as the
 * value of a single .ilike(column, value) call.
 */
export function cleanQuery(v: unknown): string {
  if (typeof v !== "string") return "";
  return v
    .normalize("NFKC")
    .replace(/[^\p{L}\p{N} '&-]/gu, " ")
    .replace(/\s+/g, " ")
    .trim()
    .slice(0, 60);
}

/** Escape LIKE wildcards in already-cleaned text so users can't force `%%%`. */
export function likePattern(clean: string): string {
  return `%${clean.replace(/[\\%_]/g, (m) => "\\" + m)}%`;
}

export function parsePage(v: unknown): number {
  const n = typeof v === "string" ? parseInt(v, 10) : NaN;
  if (!Number.isFinite(n) || n < 1) return 1;
  return Math.min(n, MAX_PAGE);
}

/** Categories are free text in the DB; accept only a safe slug-ish value. */
export function cleanCategory(v: unknown): string {
  if (typeof v !== "string") return "";
  return v.replace(/[^\p{L}\p{N} &'/-]/gu, "").trim().slice(0, 40);
}
