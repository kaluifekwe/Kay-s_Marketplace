/**
 * Turn a failed `functions.invoke` into the message the function actually sent.
 *
 * supabase-js rejects a non-2xx with `FunctionsHttpError`, whose `message` is
 * always the generic "Edge Function returned a non-2xx status code". The real
 * reason is the response body, reachable only by reading `error.context`, which
 * is an unread `Response`. Without this every server-side refusal, including the
 * ones our functions word carefully for an operator, arrives as that same
 * sentence, and diagnosing a failed money action means going to the dashboard
 * logs instead of reading the screen.
 *
 * `context` can only be consumed once, so call this exactly once per error.
 */
export async function fnError(e: unknown, fallback = "Could not complete that."): Promise<string> {
  const anyErr = e as any;
  const ctx = anyErr?.context;

  if (ctx && typeof ctx.json === "function") {
    try {
      const body = await ctx.json();
      const msg = body?.message || body?.error;
      if (msg) return String(msg);
    } catch {
      // Not JSON. Fall through to the text body, then to the generic message.
      try {
        const text = await ctx.text?.();
        if (text) return String(text).slice(0, 300);
      } catch {
        /* give up and use the fallback below */
      }
    }
  }

  if (typeof ctx?.error === "string") return ctx.error;
  return String(anyErr?.message || fallback);
}
