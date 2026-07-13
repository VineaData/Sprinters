// ============================================================================
//  Edge Function: mp-webhook
//  Recibe las notificaciones de Mercado Pago y actualiza el estado de la
//  suscripción en la base. NUNCA confiar en el redirect del navegador como
//  confirmación de pago: la verdad llega por acá.
//
//  config.toml → verify_jwt = false (MP no manda JWT de Supabase).
//  La autenticidad se valida con la firma x-signature de MP.
//
//  Secrets:
//    MP_ACCESS_TOKEN    → para consultar el estado real en la API de MP
//    MP_WEBHOOK_SECRET  → clave de firma (MP → Webhooks → "Firma secreta")
//  Inyectados por Supabase:
//    SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY
// ============================================================================
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const MP_TOKEN = Deno.env.get("MP_ACCESS_TOKEN")!;
const WEBHOOK_SECRET = Deno.env.get("MP_WEBHOOK_SECRET") ?? "";

const admin = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
);

// ── Validación de firma de MP (HMAC-SHA256) ───────────────────────────────
//  MP arma el manifest: id:<dataID>;request-id:<x-request-id>;ts:<ts>;
//  y firma con tu MP_WEBHOOK_SECRET. Comparamos contra el v1 del header.
async function validSignature(req: Request, dataId: string): Promise<boolean> {
  if (!WEBHOOK_SECRET) return true; // sin secret configurado → no bloquear (solo para pruebas iniciales)
  const sig = req.headers.get("x-signature") ?? "";
  const reqId = req.headers.get("x-request-id") ?? "";
  const parts = Object.fromEntries(sig.split(",").map((p) => p.split("=").map((s) => s.trim())));
  const ts = parts["ts"]; const v1 = parts["v1"];
  if (!ts || !v1) return false;

  const manifest = `id:${dataId};request-id:${reqId};ts:${ts};`;
  const key = await crypto.subtle.importKey(
    "raw", new TextEncoder().encode(WEBHOOK_SECRET),
    { name: "HMAC", hash: "SHA-256" }, false, ["sign"],
  );
  const mac = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(manifest));
  const hex = [...new Uint8Array(mac)].map((b) => b.toString(16).padStart(2, "0")).join("");
  return hex === v1;
}

// 30 días desde ahora (ciclo móvil de la membresía)
const plus30 = () => new Date(Date.now() + 30 * 864e5).toISOString();

Deno.serve(async (req) => {
  try {
    const url = new URL(req.url);
    const body = await req.json().catch(() => ({} as Record<string, unknown>));
    // MP manda el tipo en query (?type=) o en el body (.type / .action)
    const type = url.searchParams.get("type") ?? (body as any).type ?? "";
    const dataId = url.searchParams.get("data.id") ?? (body as any)?.data?.id ?? "";

    if (!(await validSignature(req, String(dataId)))) {
      console.warn("Firma inválida — descartado");
      return new Response("invalid signature", { status: 401 });
    }

    // ── Eventos de suscripción (preapproval) ───────────────────────────────
    if (type === "subscription_preapproval" || type === "preapproval") {
      const r = await fetch(`https://api.mercadopago.com/preapproval/${dataId}`, {
        headers: { "Authorization": `Bearer ${MP_TOKEN}` },
      });
      const pre = await r.json();
      const mpStatus = pre?.status; // authorized | paused | cancelled | pending

      const map: Record<string, string> = {
        authorized: "active",
        paused: "paused",
        cancelled: "cancelled",
        pending: "pending",
      };
      const newStatus = map[mpStatus] ?? "pending";

      const patch: Record<string, unknown> = { status: newStatus };
      if (newStatus === "active") patch.current_period_end = plus30();

      const { data: sub } = await admin
        .from("subscriptions").update(patch).eq("mp_sub_id", String(dataId))
        .select("id").maybeSingle();

      // Si se canceló, liberar el cupo del programa
      if (newStatus === "cancelled" && sub?.id) {
        await admin.rpc("release_running_seat", { p_sub_id: sub.id });
      }
      return new Response("ok", { status: 200 });
    }

    // ── Pagos recurrentes (cada renovación mensual) ────────────────────────
    if (type === "subscription_authorized_payment" || type === "payment") {
      const r = await fetch(`https://api.mercadopago.com/v1/payments/${dataId}`, {
        headers: { "Authorization": `Bearer ${MP_TOKEN}` },
      });
      const pay = await r.json();
      const preId = pay?.metadata?.preapproval_id ?? pay?.point_of_interaction?.transaction_data?.subscription_id;

      if (pay?.status === "approved" && preId) {
        await admin.from("subscriptions")
          .update({ status: "active", current_period_end: plus30() })
          .eq("mp_sub_id", String(preId));
      } else if (pay?.status === "rejected" && preId) {
        await admin.from("subscriptions").update({ status: "past_due" }).eq("mp_sub_id", String(preId));
      }
      return new Response("ok", { status: 200 });
    }

    return new Response("ignored", { status: 200 });
  } catch (e) {
    console.error("webhook error:", e);
    // Responder 200 igual para que MP no reintente en loop por un error nuestro
    return new Response("error-handled", { status: 200 });
  }
});
