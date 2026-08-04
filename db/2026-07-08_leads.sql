-- ================================================================
-- LEADS · captura de emails desde la landing (form #join)
-- Fecha: 2026-07-08
-- Correr en Supabase (SQL Editor) igual que las migraciones anteriores.
-- ================================================================

CREATE TABLE IF NOT EXISTS public.leads (
  id          UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  email       TEXT        NOT NULL,
  source      TEXT        NOT NULL DEFAULT 'landing',  -- landing / landing-mobile / evento / etc.
  created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CONSTRAINT uq_leads_email CHECK (email = lower(email)),
  CONSTRAINT chk_leads_email_format CHECK (email ~* '^[^@\s]+@[^@\s]+\.[^@\s]+$')
);

-- Un mismo mail no se duplica (el frontend trata el 23505 como éxito)
CREATE UNIQUE INDEX IF NOT EXISTS uq_leads_email_idx ON public.leads (email);

ALTER TABLE public.leads ENABLE ROW LEVEL SECURITY;

-- Cualquiera (anon o logueado) puede dejar su mail…
DROP POLICY IF EXISTS "leads_insert_public" ON public.leads;
CREATE POLICY "leads_insert_public"
  ON public.leads FOR INSERT TO anon, authenticated
  WITH CHECK (true);

-- …pero nadie los lee desde el cliente. Solo service_role (panel/export).
GRANT INSERT ON public.leads TO anon, authenticated;
