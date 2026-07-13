// ============================================================================
//  Edge Function: create-subscription
//  Crea una suscripción mensual (preapproval) en Mercado Pago para el usuario
//  logueado y devuelve el init_point para redirigirlo a pagar.
//
//  Secrets necesarios (supabase secrets set ...):
//    MP_ACCESS_TOKEN   → token de Mercado Pago (TEST-... para pruebas)
//    SITE_URL          → base del sitio para back_url (ej: https://xxxx.ngrok-free.app)
//  Inyectados por Supabase automáticamente:
//    SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, SUPABASE_ANON_KEY
// ============================================================================
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json" } });

// Nombre de plan → datos de cobro
const PLANS: Record<string, { name: string; amount: number }> = {
  "Training Core": { name: "Training Core", amount: 35000 },
  "Training Pro":  { name: "Training Pro",  amount: 50000 },
};

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "Método no permitido" }, 405);

  try {
    const MP_TOKEN = Deno.env.get("MP_ACCESS_TOKEN");
    const SITE_URL = Deno.env.get("SITE_URL") ?? "";
    if (!MP_TOKEN) return json({ error: "Falta MP_ACCESS_TOKEN en el servidor" }, 500);

    // ── 1. Identificar al usuario por su JWT ────────────────────────────────
    const authHeader = req.headers.get("Authorization") ?? "";
    const userClient = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_ANON_KEY")!,
      { global: { headers: { Authorization: authHeader } } },
    );
    const { data: { user }, error: userErr } = await userClient.auth.getUser();
    if (userErr || !user) return json({ error: "No autenticado" }, 401);

    // ── 2. Resolver el plan ─────────────────────────────────────────────────
    const { plan } = await req.json().catch(() => ({}));
    const planCfg = PLANS[plan];
    if (!planCfg) return json({ error: "Plan inválido" }, 400);

    // ── 3. Cliente admin (service_role) para leer plan/programa y escribir sub ─
    const admin = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
    );

    const { data: dbPlan } = await admin
      .from("membership_plans").select("id").eq("name", planCfg.name).single();
    if (!dbPlan) return json({ error: "Plan no encontrado en la base" }, 500);

    const { data: program } = await admin
      .from("programs").select("id, total_capacity, enrolled_count")
      .eq("branch", "running").eq("is_active", true).limit(1).single();
    if (!program) return json({ error: "No hay programa de running activo" }, 500);

    // ── 4. Cupo (chequeo simple; el límite duro real está en la DB) ──────────
    if (program.enrolled_count >= program.total_capacity) {
      return json({ error: "CUPO_AGOTADO", waitlist: true }, 409);
    }

    // Evitar doble suscripción activa/pendiente
    const { data: existing } = await admin
      .from("subscriptions").select("id, status")
      .eq("user_id", user.id).in("status", ["active", "pending"]).limit(1);
    if (existing && existing.length) {
      return json({ error: "Ya tenés una suscripción en curso." }, 409);
    }

    // ── 5. Crear preapproval (suscripción mensual) en Mercado Pago ───────────
    const preapprovalBody = {
      reason: `Sprinters Running Team — ${planCfg.name}`,
      external_reference: `${user.id}:${planCfg.name}`,
      payer_email: user.email,
      back_url: `${SITE_URL}/Cuenta.html?sub=ok`,
      auto_recurring: {
        frequency: 1,
        frequency_type: "months",
        transaction_amount: planCfg.amount,
        currency_id: "ARS",
      },
      status: "pending",
    };

    const mpRes = await fetch("https://api.mercadopago.com/preapproval", {
      method: "POST",
      headers: { "Authorization": `Bearer ${MP_TOKEN}`, "Content-Type": "application/json" },
      body: JSON.stringify(preapprovalBody),
    });
    const mp = await mpRes.json();
    if (!mpRes.ok) {
      console.error("MP preapproval error:", mp);
      return json({ error: "Mercado Pago rechazó la solicitud", detail: mp }, 502);
    }

    // ── 6. Registrar la suscripción como 'pending' (la activa el webhook) ────
    const { error: insErr } = await admin.from("subscriptions").insert({
      user_id: user.id,
      plan_id: dbPlan.id,
      program_id: program.id,
      mp_sub_id: mp.id,
      status: "pending",
    });
    if (insErr) console.error("insert subscription error:", insErr);

    // Reservar cupo (best-effort; el webhook lo libera si nunca paga)
    await admin.from("programs")
      .update({ enrolled_count: program.enrolled_count + 1 })
      .eq("id", program.id);

    return json({ init_point: mp.init_point, preapproval_id: mp.id });
  } catch (e) {
    console.error(e);
    return json({ error: String(e?.message ?? e) }, 500);
  }
});
