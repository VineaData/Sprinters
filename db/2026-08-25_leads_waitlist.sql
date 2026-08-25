-- ================================================================
-- LEADS · listas de espera por experiencia (Pádel, Trekking)
-- Fecha: 2026-08-25
-- Correr en Supabase (SQL Editor) igual que las migraciones anteriores.
-- ================================================================
--
-- POR QUÉ
-- La sección "Experiencias" de la landing suma dos pilares que todavía no
-- existen como producto: Pádel y Trekking. Sus CTA no llevan a una página,
-- llevan al form de #join y guardan el lead con source='padel' / 'trekking',
-- para medir demanda real antes de invertir en armarlos.
--
-- El problema: `uq_leads_email_idx` es UNIQUE sobre (email) a secas. Un mail
-- que ya había dejado sus datos como source='landing' choca con el 23505, y
-- como el frontend trata ese código como éxito, el interés en Pádel se
-- perdía en silencio — justo el dato que queremos medir.
--
-- La solución: la unicidad pasa a ser (email, source). Un mismo mail puede
-- estar en la lista general y además en la de Pádel, pero no dos veces en
-- la misma lista. El 23505 sigue significando "ya estabas anotado acá", así
-- que el frontend no cambia su manejo de errores.
--
-- OJO AL EXPORTAR: desde ahora un mail puede aparecer en más de una fila.
-- Cualquier conteo de "cuántos leads tenemos" necesita DISTINCT email.
-- ================================================================

DROP INDEX IF EXISTS public.uq_leads_email_idx;

CREATE UNIQUE INDEX IF NOT EXISTS uq_leads_email_source_idx
  ON public.leads (email, source);

COMMENT ON COLUMN public.leads.source IS
  'Origen del lead: landing / landing-mobile / evento / padel / trekking. '
  'Único junto con email: un mail puede estar en varias listas, no dos veces en la misma.';
