#!/usr/bin/env python3
"""E2E test del flujo create-subscription. Lee keys del .env, no las imprime.
  python db/test_subscribe.py run      → crea user test, saca JWT, llama la función
  python db/test_subscribe.py clean <user_id>  → borra sub + resetea cupo + borra user
"""
import json, sys, time, urllib.request, urllib.error

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

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
        with urllib.request.urlopen(r) as resp:
            return resp.status, resp.read().decode()
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode()

def main():
    env = load_env()
    anon = env["NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY"]
    service = env["SUPABASE_SERVICE_ROLE_KEY"]
    cmd = sys.argv[1] if len(sys.argv) > 1 else "run"

    if cmd == "run":
        email = f"sprinters-e2e-{int(time.time())}@example.com"
        pwd = "Test-1234-e2e!"
        # 1) crear user confirmado (admin / service_role)
        st, out = req("POST", f"{URL}/auth/v1/admin/users",
                      {"apikey": service, "Authorization": f"Bearer {service}", "Content-Type": "application/json"},
                      {"email": email, "password": pwd, "email_confirm": True})
        if st >= 300:
            print(f"FALLO crear user HTTP {st}: {out[:300]}"); sys.exit(1)
        uid = json.loads(out)["id"]
        print(f"user test creado: {uid}")

        # 2) login → JWT
        st, out = req("POST", f"{URL}/auth/v1/token?grant_type=password",
                      {"apikey": anon, "Content-Type": "application/json"},
                      {"email": email, "password": pwd})
        if st >= 300:
            print(f"FALLO login HTTP {st}: {out[:300]}"); sys.exit(1)
        jwt = json.loads(out)["access_token"]
        print("JWT obtenido OK")

        # 3) llamar a create-subscription
        st, out = req("POST", f"{URL}/functions/v1/create-subscription",
                      {"apikey": anon, "Authorization": f"Bearer {jwt}", "Content-Type": "application/json"},
                      {"plan": "Training Core"})
        print(f"\n=== create-subscription → HTTP {st} ===")
        try:
            j = json.loads(out)
            if j.get("init_point"):
                print("✅ init_point:", j["init_point"])
                print("   preapproval_id:", j.get("preapproval_id"))
            else:
                print(json.dumps(j, indent=2)[:1200])
        except Exception:
            print(out[:1200])
        print(f"\n>> para limpiar: python db/test_subscribe.py clean {uid}")

    elif cmd == "clean":
        uid = sys.argv[2]
        st, out = req("DELETE", f"{URL}/auth/v1/admin/users/{uid}",
                      {"apikey": service, "Authorization": f"Bearer {service}"})
        print(f"delete user HTTP {st}")

if __name__ == "__main__":
    main()
