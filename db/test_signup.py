#!/usr/bin/env python3
"""E2E del alta de cuentas. Imita el signUp() del frontend (options.data) y verifica:
  1) trigger handle_new_auth_user() crea public.users con todos los campos
  2) RLS: el usuario lee SU perfil
  3) seguridad: el usuario NO puede subir is_admin (fix de escalada)
  4) update normal (first_name) sí funciona
Limpia el user al final. Uso: python db/test_signup.py
"""
import json, sys, time, urllib.request, urllib.error
try: sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception: pass

URL = "https://lzvsttrbofnktnilunwd.supabase.co"

def load_env(path=".env"):
    env = {}
    for line in open(path, encoding="utf-8"):
        line = line.strip()
        if line and not line.startswith("#") and "=" in line:
            k, v = line.split("=", 1); env[k.strip()] = v.strip()
    return env

def req(method, url, headers, body=None):
    data = json.dumps(body).encode() if body is not None else None
    r = urllib.request.Request(url, data=data, method=method, headers=headers)
    try:
        with urllib.request.urlopen(r) as resp: return resp.status, resp.read().decode()
    except urllib.error.HTTPError as e: return e.code, e.read().decode()

def ok(cond): return "[OK]" if cond else "[FAIL]"

def main():
    env = load_env()
    anon = env["NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY"]
    service = env["SUPABASE_SERVICE_ROLE_KEY"]
    H_anon = {"apikey": anon, "Content-Type": "application/json"}
    H_srv  = {"apikey": service, "Authorization": f"Bearer {service}", "Content-Type": "application/json"}

    email = f"sprinters-signup-{int(time.time())}@example.com"
    pwd = "Test-1234-signup!"
    # Mismos campos que manda el frontend en options.data del signUp()
    form = {"first_name": "Lucía", "last_name": "Romero", "age": "27", "sex": "F",
            "origin": "godoy-cruz", "emergency_contact": "Mamá · +5492610000000",
            "phone": "+5492615555555", "how_heard": "instagram"}

    print(f"== Signup test: {email} ==\n")

    # 1) Crear cuenta con los mismos metadatos que manda el frontend.
    #    Usamos admin API (email_confirm=True) porque el endpoint público exige
    #    un mail entregable real; el trigger handle_new_auth_user() es el mismo.
    st, out = req("POST", f"{URL}/auth/v1/admin/users", H_srv,
                  {"email": email, "password": pwd, "email_confirm": True, "user_metadata": form})
    print(f"1) alta de cuenta -> HTTP {st}")
    if st >= 300: print("   ", out[:400]); sys.exit(1)
    uid = json.loads(out)["id"]
    print(f"   user id: {uid}")

    # login -> JWT (para testear RLS como el usuario final)
    st2, out2 = req("POST", f"{URL}/auth/v1/token?grant_type=password", H_anon, {"email": email, "password": pwd})
    jwt = json.loads(out2).get("access_token") if st2 < 300 else None
    print(f"   login -> {ok(bool(jwt))} (HTTP {st2})")

    # 2) Verificar fila en public.users (via service_role, bypassa RLS)
    st, out = req("GET", f"{URL}/rest/v1/users?id=eq.{uid}&select=*", H_srv)
    rows = json.loads(out) if st < 300 else []
    row = rows[0] if rows else {}
    print(f"\n2) perfil creado por el trigger -> {ok(bool(row))}")
    checks = {
        "first_name": "Lucía", "last_name": "Romero", "age": 27, "sex": "F",
        "origin": "godoy-cruz", "emergency_contact": "Mamá · +5492610000000",
        "phone": "+5492615555555", "how_heard": "instagram",
    }
    for k, exp in checks.items():
        got = row.get(k)
        print(f"   {ok(str(got) == str(exp))} {k}: {got!r}")
    print(f"   {ok(row.get('is_admin') is False)} is_admin por defecto False: {row.get('is_admin')!r}")
    print(f"   {ok(row.get('total_km') in ('0','0.00',0))} total_km=0, eventos=0, deleted_at=None: "
          f"{row.get('total_km')!r}/{row.get('social_events_attended')!r}/{row.get('deleted_at')!r}")

    rls_admin_blocked = None
    if jwt:
        H_usr = {"apikey": anon, "Authorization": f"Bearer {jwt}", "Content-Type": "application/json"}
        # 3) RLS: leer SU perfil
        st, out = req("GET", f"{URL}/rest/v1/users?id=eq.{uid}&select=id,first_name,is_admin", H_usr)
        mine = json.loads(out) if st < 300 else []
        print(f"\n3) RLS lee su propio perfil -> {ok(len(mine) == 1)} (HTTP {st}, filas {len(mine)})")

        # 4) SEGURIDAD: intentar subir is_admin -> debe FALLAR
        st, out = req("PATCH", f"{URL}/rest/v1/users?id=eq.{uid}",
                      {**H_usr, "Prefer": "return=representation"}, {"is_admin": True})
        rls_admin_blocked = st >= 400
        print(f"\n4) intento de auto-promoverse a admin -> {ok(rls_admin_blocked)} "
              f"(HTTP {st} — esperado 401/403)")
        print("   ", out[:160].replace("\n", " "))

        # 5) update normal permitido (first_name)
        st, out = req("PATCH", f"{URL}/rest/v1/users?id=eq.{uid}",
                      {**H_usr, "Prefer": "return=representation"}, {"first_name": "LucíaEditado"})
        print(f"\n5) editar su nombre (permitido) -> {ok(st < 300)} (HTTP {st})")

        # confirmar que is_admin NO cambió en la base
        st, out = req("GET", f"{URL}/rest/v1/users?id=eq.{uid}&select=is_admin", H_srv)
        still = json.loads(out)[0]["is_admin"] if st < 300 else None
        print(f"   {ok(still is False)} is_admin en la base sigue False: {still!r}")

    # cleanup
    req("DELETE", f"{URL}/auth/v1/admin/users/{uid}", H_srv)  # best-effort
    print(f"\n>> cleanup: si el delete falló, corré: python db/sb_mgmt.py query \"delete from auth.users where email like 'sprinters-signup-%';\"")

if __name__ == "__main__":
    main()
