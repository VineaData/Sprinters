-- ================================================================
--  FIX · handle_new_auth_user() · 2026-06-25
--  La versión en producción solo copiaba first_name/last_name al perfil.
--  Esta versión copia TODOS los campos del formulario de signup que el
--  frontend manda en options.data: age, sex, origin, emergency_contact,
--  phone, how_heard. Idempotente (CREATE OR REPLACE).
-- ================================================================
CREATE OR REPLACE FUNCTION public.handle_new_auth_user()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  INSERT INTO public.users (id, first_name, last_name, age, sex, origin, emergency_contact, phone, how_heard)
  VALUES (
    NEW.id,
    COALESCE(NULLIF(trim(NEW.raw_user_meta_data->>'first_name'), ''), ''),
    COALESCE(NULLIF(trim(NEW.raw_user_meta_data->>'last_name'),  ''), ''),
    CASE
      WHEN NEW.raw_user_meta_data->>'age' IS NOT NULL AND NEW.raw_user_meta_data->>'age' != ''
      THEN (NEW.raw_user_meta_data->>'age')::smallint
      ELSE NULL
    END,
    NULLIF(trim(NEW.raw_user_meta_data->>'sex'), ''),
    NULLIF(trim(NEW.raw_user_meta_data->>'origin'), ''),
    NULLIF(trim(NEW.raw_user_meta_data->>'emergency_contact'), ''),
    NULLIF(trim(NEW.raw_user_meta_data->>'phone'), ''),
    NULLIF(trim(NEW.raw_user_meta_data->>'how_heard'), '')
  )
  ON CONFLICT (id) DO NOTHING;
  RETURN NEW;
END;
$$;
