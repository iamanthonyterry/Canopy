// Sends a Canopy workflow notification from canopy@send.rosesashumans.com via Resend.
//
// Canopy calls this with the signed-in person's Supabase session, so only
// people signed in to the church site can send. The Resend key lives here as a
// secret and never reaches the app.
//
// Secrets: RESEND_API_KEY (required), NOTIFY_FROM (optional, default below).
// Deploy:  supabase functions deploy send-notification
//          supabase secrets set RESEND_API_KEY=re_...

import { createClient } from "npm:@supabase/supabase-js@2";

const FROM = Deno.env.get("NOTIFY_FROM") ?? "Canopy <canopy@send.rosesashumans.com>";
const MAX_RECIPIENTS = 20;
const MAX_SUBJECT = 300;
const MAX_BODY = 200_000;
const EMAIL = /^[^\s@<>"]+@[^\s@<>"]+\.[^\s@<>"]+$/;

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, apikey, content-type",
};

function reply(status: number, body: Record<string, unknown>) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...cors, "Content-Type": "application/json" },
  });
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response(null, { headers: cors });
  if (req.method !== "POST") return reply(405, { error: "Use POST." });

  const authorization = req.headers.get("Authorization") ?? "";
  const supabase = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_ANON_KEY")!,
    { global: { headers: { Authorization: authorization } } },
  );
  const { data: { user }, error: authError } = await supabase.auth.getUser();
  if (authError || !user) return reply(401, { error: "Sign in again to send email." });

  let input: { to?: unknown; subject?: unknown; body?: unknown; isHTML?: unknown };
  try { input = await req.json(); } catch { return reply(400, { error: "Invalid request." }); }

  const to = Array.isArray(input.to) ? input.to.map((v) => String(v).trim()) : [];
  const subject = typeof input.subject === "string" ? input.subject : "";
  const body = typeof input.body === "string" ? input.body : "";

  if (to.length === 0 || to.length > MAX_RECIPIENTS) {
    return reply(400, { error: `Send to between 1 and ${MAX_RECIPIENTS} recipients.` });
  }
  const bad = to.find((address) => !EMAIL.test(address));
  if (bad) return reply(400, { error: `"${bad}" isn't a valid email address.` });
  if (!subject || subject.length > MAX_SUBJECT) return reply(400, { error: "Subject is missing or too long." });
  if (body.length > MAX_BODY) return reply(400, { error: "Message is too long." });

  const message: Record<string, unknown> = { from: FROM, to, subject };
  if (input.isHTML === true) message.html = body; else message.text = body;
  // Replies go to the person who ran the workflow, not the no-reply sender.
  if (user.email) message.reply_to = user.email;

  const res = await fetch("https://api.resend.com/emails", {
    method: "POST",
    headers: {
      Authorization: `Bearer ${Deno.env.get("RESEND_API_KEY")}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify(message),
  });

  if (!res.ok) {
    const detail = await res.json().catch(() => ({}));
    console.error("resend failed", res.status, detail);
    return reply(502, { error: detail.message ?? `Email service returned ${res.status}.` });
  }

  console.log(`sent by ${user.id} to ${to.length} recipient(s)`);
  return reply(200, { ok: true });
});
