// ============================================================================
//  Edge Function: admin-create-user
//  Crea un usuario nuevo (auth + perfil) desde el panel de administración.
//  Necesita el service_role key para invocar auth.admin.createUser(), por eso
//  esto NO se puede hacer directo desde el navegador con la clave pública.
//
//  Quién puede llamarla: solo un usuario logueado con is_admin = true en
//  public.users (se valida acá adentro, igual que en las funciones SQL
//  admin_* de la migración 2026-07-13_admin_crud.sql).
//
//  Deploy:
//    supabase functions deploy admin-create-user
//  (usa los mismos secrets ya configurados: SUPABASE_URL,
//   SUPABASE_SERVICE_ROLE_KEY, SUPABASE_ANON_KEY — los inyecta Supabase solo)
// ============================================================================
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json" } });

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "Método no permitido" }, 405);

  try {
    // ── 1. Identificar a quien llama y confirmar que es admin ───────────────
    const authHeader = req.headers.get("Authorization") ?? "";
    const callerClient = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_ANON_KEY")!,
      { global: { headers: { Authorization: authHeader } } },
    );
    const { data: { user: caller }, error: callerErr } = await callerClient.auth.getUser();
    if (callerErr || !caller) return json({ error: "No autenticado" }, 401);

    const admin = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
    );

    const { data: callerProfile } = await admin
      .from("users").select("is_admin").eq("id", caller.id).maybeSingle();
    if (!callerProfile?.is_admin) return json({ error: "Solo un admin puede crear usuarios" }, 403);

    // ── 2. Body ───────────────────────────────────────────────────────────
    const body = await req.json().catch(() => ({}));
    const { email, password, first_name, last_name, phone, is_admin } = body ?? {};
    if (!email || !password) return json({ error: "Faltan email o password" }, 400);
    if (String(password).length < 8) return json({ error: "La contraseña debe tener al menos 8 caracteres" }, 400);

    // ── 3. Crear en auth.users (confirmado — lo crea un admin, no hace falta
    //      que confirme el mail) ─────────────────────────────────────────────
    const { data: created, error: createErr } = await admin.auth.admin.createUser({
      email,
      password,
      email_confirm: true,
      user_metadata: { first_name: first_name ?? "", last_name: last_name ?? "" },
    });
    if (createErr || !created?.user) {
      return json({ error: createErr?.message ?? "No pudimos crear el usuario" }, 400);
    }

    // ── 4. handle_new_auth_user() ya crea la fila base en public.users;
    //      completamos los campos extra que vinieron del form admin ─────────
    const { error: upsertErr } = await admin.from("users").upsert({
      id: created.user.id,
      first_name: first_name ?? "",
      last_name: last_name ?? "",
      phone: phone ?? null,
      is_admin: !!is_admin,
    });
    if (upsertErr) console.error("[admin-create-user] upsert profile:", upsertErr);

    return json({ id: created.user.id, email: created.user.email });
  } catch (e) {
    console.error(e);
    return json({ error: String(e?.message ?? e) }, 500);
  }
});
