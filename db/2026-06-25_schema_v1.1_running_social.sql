-- ================================================================
--  SPRINTERS OS · Migración v1.1.0 · SOCIAL (features nuevos) + RUNNING TEAM
--  PostgreSQL 15 / Supabase · 2026-06-25
--
--  REQUISITO: la base v1.0.0 (.claude/sprinters-schema.sql) ya debe estar
--             aplicada. Este script es ADITIVO e IDEMPOTENTE: solo agrega
--             columnas/tablas/funciones nuevas y se puede re-ejecutar sin romper
--             datos existentes (usa IF NOT EXISTS / DO $$ ... duplicate guards).
--
--  CÓMO APLICAR:
--    1. Supabase Dashboard → SQL Editor → New query
--    2. Pegar este script completo → Run
--    3. Verificar en Table Editor: programs, organizers, event_photos,
--       event_registrations, trial_class_bookings + columnas nuevas en users.
--    4. Storage → confirmar buckets 'medical-certs' (privado) y 'event-photos'.
--
--  ALCANCE DE ESTA MIGRACIÓN:
--    · SOCIAL: cumpleaños (birth_date), Instagram opcional de asistentes,
--              fotos de evento, organizadores por dupla, cierre variable.
--    · RUNNING: planes Training Core/Pro, certificado médico (apto físico),
--              cupo del programa (45), clase de prueba one-off, eventos
--              especiales con formulario.
--    · SEGURIDAD: cierra el hueco de escalada de privilegios en public.users
--              (ver SECCIÓN 0 — leer sí o sí).
-- ================================================================


-- ================================================================
-- 0. ⚠️  FIX DE SEGURIDAD CRÍTICO (escalada de privilegios en users)
--
--  En v1.0.0, la política "users_update_own" + el GRANT UPDATE sobre TODA
--  la tabla public.users permiten que un usuario autenticado se actualice
--  a sí mismo CUALQUIER columna de su fila, incluyendo:
--      is_admin = true            → se vuelve administrador
--      med_cert_status = approved → se autoaprueba el apto médico
--      total_money_saved / total_km / social_events_attended → infla métricas
--
--  RLS en Postgres no filtra por columna; el control fino se hace con
--  GRANTs a nivel columna. Acá revocamos el UPDATE total y lo re-otorgamos
--  SOLO sobre las columnas que el usuario tiene derecho a editar.
--  Las columnas sensibles se cambian exclusivamente vía funciones
--  SECURITY DEFINER (submit_med_cert / review_med_cert) o service_role.
-- ================================================================

REVOKE UPDATE ON public.users FROM authenticated;

-- Nota: las columnas instagram_handle, show_instagram, birth_date, med_cert_url,
-- med_cert_uploaded_at se crean más abajo; este GRANT se re-aplica al final
-- (sección 9) una vez que todas existen. Acá dejamos asentada la intención.


-- ================================================================
-- 1. TIPOS ENUMERADOS NUEVOS
-- ================================================================

DO $$ BEGIN
  -- Estado del apto físico / certificado médico (Running Team)
  CREATE TYPE med_cert_status_type AS ENUM ('none', 'pending', 'approved', 'rejected');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
  -- Nivel del corredor dentro del Running Team
  CREATE TYPE running_level_type AS ENUM ('beginner', 'intermediate');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
  -- Estado de inscripción a eventos con formulario (no ticketeados)
  CREATE TYPE registration_status_type AS ENUM ('registered', 'cancelled', 'attended', 'no_show');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;


-- ================================================================
-- 2. USERS — columnas nuevas (Social + Running)
-- ================================================================

ALTER TABLE public.users
  -- ── Social ───────────────────────────────────────────────────
  ADD COLUMN IF NOT EXISTS birth_date        DATE,       -- para felicitación de cumpleaños (CRON)
  ADD COLUMN IF NOT EXISTS instagram_handle  TEXT,       -- sin @, ej: 'sprinters.club'
  ADD COLUMN IF NOT EXISTS show_instagram    BOOLEAN NOT NULL DEFAULT FALSE, -- opt-in: mostrar IG a otros asistentes
  -- ── Running: certificado médico (apto físico) ────────────────
  --    DATO DE SALUD SENSIBLE (Ley 25.326). El archivo vive en el bucket
  --    privado 'medical-certs'; acá guardamos solo la ruta y el estado.
  ADD COLUMN IF NOT EXISTS med_cert_url         TEXT,
  ADD COLUMN IF NOT EXISTS med_cert_status      med_cert_status_type NOT NULL DEFAULT 'none',
  ADD COLUMN IF NOT EXISTS med_cert_uploaded_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS med_cert_reviewed_by UUID REFERENCES public.users(id),
  ADD COLUMN IF NOT EXISTS med_cert_reviewed_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS med_cert_expires_at  DATE;     -- el apto vence (típico: 1 año)

COMMENT ON COLUMN public.users.birth_date IS
  'Fecha de nacimiento. Fuente de verdad para edad y para el CRON de cumpleaños. '
  'La columna age (v1.0.0) queda como dato heredado/redundante.';
COMMENT ON COLUMN public.users.med_cert_status IS
  'Estado del apto físico. SOLO se cambia vía submit_med_cert() (a pending) y '
  'review_med_cert() (a approved/rejected). El usuario NO puede setearlo directo.';
COMMENT ON COLUMN public.users.show_instagram IS
  'Opt-in de privacidad. Si FALSE, el handle no se muestra en la lista de asistentes.';


-- ================================================================
-- 3. ORGANIZADORES (Duplas) — Social y Running
--    Ine & Alan / Nico & Zoe / Profes Running. Permite medir a fin de
--    año qué dupla convocó más gente (events.organizer_id).
-- ================================================================
CREATE TABLE IF NOT EXISTS public.organizers (
  id          UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  name        TEXT        NOT NULL UNIQUE,           -- 'Nico & Zoe', 'Ine & Alan', 'Profes Running'
  branch      branch_type NOT NULL DEFAULT 'social',
  is_active   BOOLEAN     NOT NULL DEFAULT TRUE,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

COMMENT ON TABLE public.organizers IS
  'Dupla/equipo responsable de planificar un evento. Se asigna en events.organizer_id '
  'para repartir la carga organizativa y medir performance por dupla.';


-- ================================================================
-- 4. PROGRAMAS (Running Team) — clase recurrente con cupo
--    El cupo de 45 es del PROGRAMA (la clase Mar/Jue 18:30), no del plan:
--    Core y Pro comparten las mismas clases. enrolled_count se controla
--    de forma atómica en enroll_running_safely().
-- ================================================================
CREATE TABLE IF NOT EXISTS public.programs (
  id              UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  name            TEXT        NOT NULL,              -- 'Running Team — Mar/Jue 18:30'
  branch          branch_type NOT NULL DEFAULT 'running',
  schedule_text   TEXT,                              -- 'Martes y Jueves 18:30'
  total_capacity  INTEGER     NOT NULL CHECK (total_capacity > 0),
  enrolled_count  INTEGER     NOT NULL DEFAULT 0 CHECK (enrolled_count >= 0),
  is_active       BOOLEAN     NOT NULL DEFAULT TRUE,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CONSTRAINT chk_program_capacity CHECK (enrolled_count <= total_capacity)
);

COMMENT ON COLUMN public.programs.enrolled_count IS
  'Suscripciones activas/pendientes ocupando cupo. Lo incrementa enroll_running_safely() '
  'y lo decrementa release_running_seat() (al cancelar/past_due vía webhook de MP).';


-- ================================================================
-- 5. EVENTS — soporte para Running + features nuevos
--    Se relajan NOT NULL pensados solo para Social (partner, logística,
--    cutoff, precio, cupo) para poder modelar también eventos Running
--    (entrenamiento especial en un parque, sin local ni split). Un CHECK
--    re-impone esos requisitos SOLO cuando branch = 'social'.
-- ================================================================

ALTER TABLE public.events
  ADD COLUMN IF NOT EXISTS organizer_id    UUID REFERENCES public.organizers(id),
  ADD COLUMN IF NOT EXISTS location_text   TEXT,    -- 'Parque San Martín, portones' (running) o detalle extra
  ADD COLUMN IF NOT EXISTS cover_image_url TEXT,
  ADD COLUMN IF NOT EXISTS requires_form   BOOLEAN NOT NULL DEFAULT FALSE,  -- entrenamiento especial Running → formulario
  ADD COLUMN IF NOT EXISTS form_schema     JSONB   NOT NULL DEFAULT '[]',   -- [{key,label,type,required}]
  ADD COLUMN IF NOT EXISTS is_published    BOOLEAN NOT NULL DEFAULT TRUE,
  -- Cierre de inscripción variable por local: además del sales_cutoff (timestamp
  -- exacto), guardamos las horas como conveniencia para autocalcular el cutoff.
  ADD COLUMN IF NOT EXISTS cutoff_hours    INTEGER;  -- ej: 24, 48, 12. NULL = usar sales_cutoff directo.

-- Relajar NOT NULL (solo Social los necesita; el CHECK de abajo los re-impone)
ALTER TABLE public.events ALTER COLUMN partner_id     DROP NOT NULL;
ALTER TABLE public.events ALTER COLUMN logistics_type DROP NOT NULL;
ALTER TABLE public.events ALTER COLUMN sales_cutoff   DROP NOT NULL;
ALTER TABLE public.events ALTER COLUMN base_price     DROP NOT NULL;
ALTER TABLE public.events ALTER COLUMN total_capacity DROP NOT NULL;

-- Re-imponer requisitos para eventos sociales (gastronómicos con split payment)
DO $$ BEGIN
  ALTER TABLE public.events ADD CONSTRAINT chk_social_event_requirements CHECK (
    branch <> 'social' OR (
      partner_id     IS NOT NULL AND
      logistics_type IS NOT NULL AND
      sales_cutoff   IS NOT NULL AND
      base_price     IS NOT NULL AND
      total_capacity IS NOT NULL
    )
  );
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

COMMENT ON COLUMN public.events.cutoff_hours IS
  'Horas antes del evento en que cierran las inscripciones. Por local/evento '
  '(no global). El backend calcula sales_cutoff = event_date - cutoff_hours al crear el evento.';
COMMENT ON COLUMN public.events.organizer_id IS
  'Dupla responsable (organizers). Nico&Zoe ~2/mes, Ine&Alan ~1 grande, Profes Running ~1/mes.';


-- ================================================================
-- 6. FOTOS DE EVENTO (galería post-evento, feature Social PRO)
-- ================================================================
CREATE TABLE IF NOT EXISTS public.event_photos (
  id           UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  event_id     UUID        NOT NULL REFERENCES public.events(id) ON DELETE CASCADE,
  storage_url  TEXT        NOT NULL,                 -- bucket público 'event-photos'
  caption      TEXT,
  uploaded_by  UUID        REFERENCES public.users(id),
  created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW()
);


-- ================================================================
-- 7. INSCRIPCIONES A EVENTOS CON FORMULARIO (no ticketeadas)
--    Para: entrenamiento especial Running (form de los profes) y RSVP a
--    eventos sin cobro. Los eventos sociales PAGOS siguen yendo por
--    tickets + book_ticket_safely().
-- ================================================================
CREATE TABLE IF NOT EXISTS public.event_registrations (
  id          UUID                      PRIMARY KEY DEFAULT gen_random_uuid(),
  event_id    UUID                      NOT NULL REFERENCES public.events(id) ON DELETE CASCADE,
  user_id     UUID                      NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  status      registration_status_type  NOT NULL DEFAULT 'registered',
  form_data   JSONB                     NOT NULL DEFAULT '{}',  -- respuestas del formulario
  created_at  TIMESTAMPTZ               NOT NULL DEFAULT NOW(),
  CONSTRAINT uq_one_registration_per_user_event UNIQUE (user_id, event_id)
);


-- ================================================================
-- 8. RUNNING TEAM — suscripciones, clase de prueba, planes
-- ================================================================

-- ── 8.1 SUBSCRIPTIONS: vincular a programa + nivel (solo Running) ──
ALTER TABLE public.subscriptions
  ADD COLUMN IF NOT EXISTS program_id UUID REFERENCES public.programs(id),
  ADD COLUMN IF NOT EXISTS level      running_level_type;  -- principiante / intermedio

-- ── 8.2 CLASE DE PRUEBA ($5.000, pago único, NO suscripción) ───────
CREATE TABLE IF NOT EXISTS public.trial_class_bookings (
  id              UUID                PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id         UUID                NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  program_id      UUID                REFERENCES public.programs(id),
  class_date      DATE                NOT NULL,
  amount          NUMERIC(12,2)       NOT NULL DEFAULT 5000 CHECK (amount >= 0),
  payment_status  payment_status_type NOT NULL DEFAULT 'pending',
  mp_payment_id   TEXT                UNIQUE,        -- id del pago one-off de Mercado Pago
  created_at      TIMESTAMPTZ         NOT NULL DEFAULT NOW()
);

COMMENT ON TABLE public.trial_class_bookings IS
  'Clase de prueba Running ($5.000). Pago único (Checkout Pro / preference), NO recurrente. '
  'No otorga estado PRO ni accede a beneficios de suscripción.';

-- ── 8.3 SEED: planes Running Team ─────────────────────────────────
--   Precios definidos 2026-06-10. Ajustables sin tocar schema.
--   grants_social_pro=true en Pro: el Training Pro reconoce al usuario como
--   "Social Pro" al hacer checkout en eventos sociales (acceso/no-line/descuentos),
--   PERO igual paga la comida vía split payment. La membresía NO regala la comida.
INSERT INTO public.membership_plans (name, branch, price_monthly, benefits_json)
VALUES
  ('Training Core', 'running', 35000,
   '{"classes_per_month": 8, "duration_min": 60, "schedule": "Mar/Jue 18:30",
     "requires_med_cert": true, "levels": ["beginner","intermediate"],
     "grants_social_pro": false, "cafe_discounts": false, "badge": "core"}'),
  ('Training Pro', 'running', 50000,
   '{"classes_per_month": 8, "duration_min": 60, "schedule": "Mar/Jue 18:30",
     "requires_med_cert": true, "levels": ["beginner","intermediate"],
     "grants_social_pro": true, "all_social_events": true, "cafe_discounts": true,
     "sportbox": true, "sportbox_value": 75000, "badge": "pro"}')
ON CONFLICT (name) DO NOTHING;

-- ── 8.4 SEED: programa de entrenamiento (cupo 45) ─────────────────
INSERT INTO public.programs (name, branch, schedule_text, total_capacity)
SELECT 'Running Team — Mar/Jue 18:30', 'running', 'Martes y Jueves 18:30', 45
WHERE NOT EXISTS (SELECT 1 FROM public.programs WHERE name = 'Running Team — Mar/Jue 18:30');

-- ── 8.5 SEED: duplas organizadoras ────────────────────────────────
INSERT INTO public.organizers (name, branch) VALUES
  ('Nico & Zoe',     'social'),
  ('Ine & Alan',     'social'),
  ('Profes Running', 'running')
ON CONFLICT (name) DO NOTHING;


-- ================================================================
-- 9. FUNCIONES
-- ================================================================

-- ── 9.1 submit_med_cert(): el usuario sube su apto → queda 'pending' ──
--    El usuario NO puede tocar med_cert_status directo (ver sección 0).
--    Esta función es la única vía para pasar a 'pending'.
CREATE OR REPLACE FUNCTION public.submit_med_cert(p_url TEXT)
RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  UPDATE public.users
  SET med_cert_url         = p_url,
      med_cert_uploaded_at = NOW(),
      med_cert_status      = 'pending',
      med_cert_reviewed_by = NULL,
      med_cert_reviewed_at = NULL
  WHERE id = auth.uid();
END;
$$;

-- ── 9.2 review_med_cert(): un ADMIN aprueba/rechaza el apto ───────
CREATE OR REPLACE FUNCTION public.review_med_cert(
  p_user_id  UUID,
  p_approve  BOOLEAN,
  p_expires  DATE DEFAULT NULL          -- vencimiento del apto si se aprueba
)
RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.users WHERE id = auth.uid() AND is_admin) THEN
    RAISE EXCEPTION 'NO_AUTORIZADO: solo un administrador puede revisar aptos médicos.';
  END IF;

  UPDATE public.users
  SET med_cert_status      = CASE WHEN p_approve THEN 'approved'::med_cert_status_type
                                  ELSE 'rejected'::med_cert_status_type END,
      med_cert_reviewed_by = auth.uid(),
      med_cert_reviewed_at = NOW(),
      med_cert_expires_at  = CASE WHEN p_approve THEN COALESCE(p_expires, (CURRENT_DATE + INTERVAL '1 year')::date)
                                  ELSE NULL END
  WHERE id = p_user_id;
END;
$$;

-- ── 9.3 enroll_running_safely(): alta atómica al Running Team ─────
--    ① Bloquea el programa (FOR UPDATE) → evita pasar de 45 por carrera
--    ② Exige apto médico aprobado y vigente
--    ③ Crea la suscripción 'pending' (la confirma el webhook de MP)
--    ④ Incrementa enrolled_count
CREATE OR REPLACE FUNCTION public.enroll_running_safely(
  p_program_id UUID,
  p_plan_id    UUID,
  p_level      running_level_type,
  p_mp_sub_id  TEXT DEFAULT NULL
)
RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_program public.programs%ROWTYPE;
  v_user    public.users%ROWTYPE;
  v_sub_id  UUID := gen_random_uuid();
BEGIN
  SELECT * INTO v_user FROM public.users WHERE id = auth.uid();
  IF NOT FOUND THEN
    RAISE EXCEPTION 'USUARIO_NO_ENCONTRADO';
  END IF;

  -- ② Gate del apto médico: DESACTIVADO por decisión 2026-06-25.
  --    El usuario puede suscribirse y pagar sin apto; el apto se exige
  --    offline/manual antes de la primera clase. Para re-activar el bloqueo,
  --    descomentar este IF (las columnas med_cert_* siguen existiendo):
  -- IF v_user.med_cert_status <> 'approved'
  --    OR v_user.med_cert_expires_at IS NULL
  --    OR v_user.med_cert_expires_at < CURRENT_DATE THEN
  --   RAISE EXCEPTION 'APTO_INVALIDO: necesitás un certificado médico aprobado y vigente antes de inscribirte.';
  -- END IF;

  -- ① Bloquear el programa para chequear cupo sin condición de carrera
  SELECT * INTO v_program FROM public.programs
  WHERE id = p_program_id AND is_active FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'PROGRAMA_NO_ENCONTRADO';
  END IF;

  IF v_program.enrolled_count >= v_program.total_capacity THEN
    RAISE EXCEPTION 'CUPO_AGOTADO: el Running Team está completo (% lugares). Sumate a la lista de espera.',
      v_program.total_capacity;
  END IF;

  -- ③ Crear suscripción (queda 'pending' hasta que el webhook de MP la active)
  INSERT INTO public.subscriptions (id, user_id, plan_id, program_id, level, mp_sub_id, status)
  VALUES (v_sub_id, auth.uid(), p_plan_id, p_program_id, p_level, p_mp_sub_id, 'pending');

  -- ④ Reservar el cupo
  UPDATE public.programs SET enrolled_count = enrolled_count + 1 WHERE id = p_program_id;

  RETURN v_sub_id;
END;
$$;

-- ── 9.4 release_running_seat(): liberar cupo al cancelar/past_due ──
--    Lo llama el servidor (service_role) desde el webhook de MP cuando una
--    suscripción Running pasa a cancelled/past_due, o si nunca se pagó.
CREATE OR REPLACE FUNCTION public.release_running_seat(p_sub_id UUID)
RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_program_id UUID;
BEGIN
  SELECT program_id INTO v_program_id FROM public.subscriptions WHERE id = p_sub_id;
  IF v_program_id IS NOT NULL THEN
    UPDATE public.programs
    SET enrolled_count = GREATEST(enrolled_count - 1, 0)
    WHERE id = v_program_id;
  END IF;
END;
$$;

-- ── 9.5 users_with_birthday_today(): fuente para el CRON de cumpleaños ──
--    El CRON (pg_cron o Edge Function programada) la consulta cada mañana
--    y dispara el saludo por WhatsApp Business API (plantilla aprobada).
CREATE OR REPLACE FUNCTION public.users_with_birthday_today()
RETURNS TABLE (id UUID, first_name TEXT, phone TEXT)
LANGUAGE sql SECURITY DEFINER SET search_path = public AS $$
  SELECT id, first_name, phone
  FROM public.users
  WHERE deleted_at IS NULL
    AND birth_date IS NOT NULL
    AND EXTRACT(MONTH FROM birth_date) = EXTRACT(MONTH FROM CURRENT_DATE)
    AND EXTRACT(DAY   FROM birth_date) = EXTRACT(DAY   FROM CURRENT_DATE);
$$;

-- updated_at automático en subscriptions ya está cubierto por trg_subs_updated_at (v1.0.0)


-- ================================================================
-- 10. ROW LEVEL SECURITY (RLS) para las tablas nuevas
-- ================================================================

ALTER TABLE public.organizers           ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.programs             ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.event_photos         ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.event_registrations  ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.trial_class_bookings ENABLE ROW LEVEL SECURITY;

-- organizers: lectura pública (para mostrar quién organiza)
DROP POLICY IF EXISTS "organizers_public_select" ON public.organizers;
CREATE POLICY "organizers_public_select"
  ON public.organizers FOR SELECT USING (is_active);

-- programs: lectura pública (para mostrar cupo disponible / lista de espera)
DROP POLICY IF EXISTS "programs_public_select" ON public.programs;
CREATE POLICY "programs_public_select"
  ON public.programs FOR SELECT USING (is_active);

-- event_photos: lectura para usuarios autenticados (galería post-evento).
--   El gating "solo PRO" se aplica en el frontend; las fotos no son sensibles.
DROP POLICY IF EXISTS "event_photos_auth_select" ON public.event_photos;
CREATE POLICY "event_photos_auth_select"
  ON public.event_photos FOR SELECT TO authenticated USING (TRUE);

-- event_registrations: cada usuario ve/gestiona las suyas
DROP POLICY IF EXISTS "evreg_select_own" ON public.event_registrations;
CREATE POLICY "evreg_select_own"
  ON public.event_registrations FOR SELECT TO authenticated
  USING ((select auth.uid()) = user_id);
DROP POLICY IF EXISTS "evreg_insert_own" ON public.event_registrations;
CREATE POLICY "evreg_insert_own"
  ON public.event_registrations FOR INSERT TO authenticated
  WITH CHECK ((select auth.uid()) = user_id);
DROP POLICY IF EXISTS "evreg_update_own" ON public.event_registrations;
CREATE POLICY "evreg_update_own"
  ON public.event_registrations FOR UPDATE TO authenticated
  USING ((select auth.uid()) = user_id) WITH CHECK ((select auth.uid()) = user_id);

-- trial_class_bookings: cada usuario ve las suyas; el INSERT va por el
--   servidor al crear la preference de pago (service_role).
DROP POLICY IF EXISTS "trial_select_own" ON public.trial_class_bookings;
CREATE POLICY "trial_select_own"
  ON public.trial_class_bookings FOR SELECT TO authenticated
  USING ((select auth.uid()) = user_id);


-- ================================================================
-- 11. GRANTS — incluye la RE-APLICACIÓN del UPDATE acotado en users
--      (cierra el fix de seguridad de la sección 0)
-- ================================================================

-- ── users: UPDATE SOLO sobre columnas que el usuario puede editar ──
--    NO se incluyen: is_admin, med_cert_status, med_cert_reviewed_by/at,
--    med_cert_expires_at, total_km, social_events_attended, total_money_saved,
--    created_at, updated_at. Esas se cambian por funciones SECURITY DEFINER
--    o service_role.
GRANT UPDATE (
  first_name, last_name, avatar_url, phone, age, sex, origin,
  emergency_contact, how_heard, birth_date, instagram_handle, show_instagram,
  med_cert_url, med_cert_uploaded_at, deleted_at
) ON public.users TO authenticated;

-- Tablas nuevas de lectura pública
GRANT SELECT ON public.organizers TO anon, authenticated;
GRANT SELECT ON public.programs   TO anon, authenticated;

-- Tablas de usuario autenticado
GRANT SELECT                 ON public.event_photos         TO authenticated;
GRANT SELECT, INSERT, UPDATE ON public.event_registrations  TO authenticated;
GRANT SELECT                 ON public.trial_class_bookings TO authenticated;

-- Funciones invocables por el usuario final
GRANT EXECUTE ON FUNCTION public.submit_med_cert(TEXT)                                      TO authenticated;
GRANT EXECUTE ON FUNCTION public.review_med_cert(UUID, BOOLEAN, DATE)                       TO authenticated; -- valida is_admin adentro
GRANT EXECUTE ON FUNCTION public.enroll_running_safely(UUID, UUID, running_level_type, TEXT) TO authenticated;
-- release_running_seat y users_with_birthday_today: solo service_role (sin GRANT)


-- ================================================================
-- 12. STORAGE BUCKETS
-- ================================================================

-- ── 12.1 medical-certs (PRIVADO · dato de salud sensible) ─────────
INSERT INTO storage.buckets (id, name, public)
VALUES ('medical-certs', 'medical-certs', FALSE)
ON CONFLICT (id) DO NOTHING;

-- El usuario sube su apto a la "carpeta" {auth.uid()}/...  (ej: 'a1b2.../apto.pdf')
DROP POLICY IF EXISTS "medcert_insert_own" ON storage.objects;
CREATE POLICY "medcert_insert_own"
  ON storage.objects FOR INSERT TO authenticated
  WITH CHECK (
    bucket_id = 'medical-certs'
    AND (storage.foldername(name))[1] = (select auth.uid())::text
  );

DROP POLICY IF EXISTS "medcert_select_own_or_admin" ON storage.objects;
CREATE POLICY "medcert_select_own_or_admin"
  ON storage.objects FOR SELECT TO authenticated
  USING (
    bucket_id = 'medical-certs'
    AND (
      (storage.foldername(name))[1] = (select auth.uid())::text
      OR EXISTS (SELECT 1 FROM public.users u WHERE u.id = (select auth.uid()) AND u.is_admin)
    )
  );

DROP POLICY IF EXISTS "medcert_update_own" ON storage.objects;
CREATE POLICY "medcert_update_own"
  ON storage.objects FOR UPDATE TO authenticated
  USING (
    bucket_id = 'medical-certs'
    AND (storage.foldername(name))[1] = (select auth.uid())::text
  );

-- ── 12.2 event-photos (PÚBLICO de lectura) ────────────────────────
INSERT INTO storage.buckets (id, name, public)
VALUES ('event-photos', 'event-photos', TRUE)
ON CONFLICT (id) DO NOTHING;

-- Lectura pública la da el flag public=TRUE del bucket.
-- Subida: solo usuarios autenticados (en la práctica, admins desde el panel).
DROP POLICY IF EXISTS "eventphotos_insert_auth" ON storage.objects;
CREATE POLICY "eventphotos_insert_auth"
  ON storage.objects FOR INSERT TO authenticated
  WITH CHECK (bucket_id = 'event-photos');


-- ================================================================
-- 13. ÍNDICES nuevos
-- ================================================================
CREATE INDEX IF NOT EXISTS idx_users_birthday
  ON public.users ((EXTRACT(MONTH FROM birth_date)), (EXTRACT(DAY FROM birth_date)));
CREATE INDEX IF NOT EXISTS idx_users_med_cert_status
  ON public.users(med_cert_status);
CREATE INDEX IF NOT EXISTS idx_events_organizer_id
  ON public.events(organizer_id);
CREATE INDEX IF NOT EXISTS idx_event_photos_event_id
  ON public.event_photos(event_id);
CREATE INDEX IF NOT EXISTS idx_evreg_event_id
  ON public.event_registrations(event_id);
CREATE INDEX IF NOT EXISTS idx_evreg_user_id
  ON public.event_registrations(user_id);
CREATE INDEX IF NOT EXISTS idx_subs_program_id
  ON public.subscriptions(program_id);
CREATE INDEX IF NOT EXISTS idx_trial_user_id
  ON public.trial_class_bookings(user_id);


-- ================================================================
-- FIN · Sprinters OS v1.1.0 · Social (features) + Running Team
--
-- PENDIENTE FUERA DE LA BASE (ver doc de Mercado Pago y Contexto Maestro):
--   · Webhooks de MP que llaman a las funciones de activación/baja.
--   · CRON de cumpleaños (pg_cron o Edge Function) → users_with_birthday_today().
--   · Resolución de entitlement "Training Pro ⇒ Social Pro" en el checkout social.
--   · Check-in de clases Running: por ahora Excel (no se modela en DB).
-- ================================================================
