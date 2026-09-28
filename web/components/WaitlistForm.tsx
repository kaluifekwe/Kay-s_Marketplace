"use client";

import { useState } from "react";
import { STATES } from "@/lib/validate";

type Status = "idle" | "sending" | "done" | "error";

export function WaitlistForm({ defaultRole }: { defaultRole?: "buyer" | "vendor" }) {
  const [email, setEmail] = useState("");
  const [role, setRole] = useState<"buyer" | "vendor">(defaultRole ?? "buyer");
  const [state, setState] = useState("");
  const [status, setStatus] = useState<Status>("idle");
  const [message, setMessage] = useState("");

  async function onSubmit(e: React.FormEvent) {
    e.preventDefault();
    if (!state) {
      setStatus("error");
      setMessage("Choose your state.");
      return;
    }
    setStatus("sending");
    try {
      const res = await fetch("/api/waitlist", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ email, role, state }),
      });
      const data = await res.json();
      if (!res.ok || !data.ok) {
        setStatus("error");
        setMessage(data.error || "Something went wrong. Try again.");
        return;
      }
      setStatus("done");
      setMessage(data.already ? "You're already on the list — we'll be in touch." : "You're on the list! We'll email you when it's your turn.");
    } catch {
      setStatus("error");
      setMessage("Could not reach the server. Check your connection and try again.");
    }
  }

  if (status === "done") {
    return <p className="waitlistDone">✅ {message}</p>;
  }

  return (
    <form id="waitlist" className="waitlistForm" onSubmit={onSubmit}>
      <div className="waitlistRoles">
        <label>
          <input type="radio" name="role" checked={role === "buyer"} onChange={() => setRole("buyer")} />
          I'm a buyer
        </label>
        <label>
          <input type="radio" name="role" checked={role === "vendor"} onChange={() => setRole("vendor")} />
          I'm a vendor
        </label>
      </div>
      <input
        type="email"
        required
        maxLength={255}
        placeholder="you@example.com"
        aria-label="Email address"
        value={email}
        onChange={(e) => setEmail(e.target.value)}
      />
      <select required value={state} onChange={(e) => setState(e.target.value)} aria-label="Your state">
        <option value="" disabled>
          Select your state
        </option>
        {STATES.map((s) => (
          <option key={s} value={s}>
            {s}
          </option>
        ))}
      </select>
      <button type="submit" disabled={status === "sending"}>
        {status === "sending" ? "Joining…" : "Join the waitlist"}
      </button>
      {status === "error" ? <p className="waitlistError">{message}</p> : null}
    </form>
  );
}
