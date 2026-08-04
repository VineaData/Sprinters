#!/usr/bin/env python3
"""Helper para operar la Supabase Management API con el PAT del .env.
Nunca imprime el token. Uso:
    python db/sb_mgmt.py validate
    python db/sb_mgmt.py migrate db/2026-06-25_schema_v1.1_running_social.sql
    python db/sb_mgmt.py query "select count(*) from public.programs;"
"""
import json, os, sys, urllib.request, urllib.error

REF = "lzvsttrbofnktnilunwd"
API = "https://api.supabase.com"

def load_env(path=".env"):
    env = {}
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            k, v = line.split("=", 1)
            env[k.strip()] = v.strip()
    return env

def call(method, path, token, body=None):
    url = API + path
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("Authorization", "Bearer " + token)
    req.add_header("Content-Type", "application/json")
    req.add_header("User-Agent", "sprinters-deploy/1.0 (+https://supabase.com)")
    try:
        with urllib.request.urlopen(req) as r:
            return r.status, r.read().decode()
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode()

def main():
    cmd = sys.argv[1] if len(sys.argv) > 1 else "validate"
    token = load_env().get("SUPABASE_ACCESS_TOKEN", "")
    if not token:
        print("ERROR: SUPABASE_ACCESS_TOKEN no está en .env"); sys.exit(1)

    if cmd == "validate":
        st, out = call("GET", f"/v1/projects/{REF}", token)
        if st == 200:
            j = json.loads(out)
            print(f"OK · proyecto: {j.get('name')} · region: {j.get('region')} · status: {j.get('status')}")
        else:
            print(f"FALLO HTTP {st}: {out[:300]}"); sys.exit(1)

    elif cmd == "migrate":
        sql = open(sys.argv[2], encoding="utf-8").read()
        st, out = call("POST", f"/v1/projects/{REF}/database/query", token, {"query": sql})
        print(f"HTTP {st}")
        print(out[:1500] if out else "(sin cuerpo)")
        if st >= 300: sys.exit(1)

    elif cmd == "get":
        st, out = call("GET", sys.argv[2], token)
        print(f"HTTP {st}"); print(out[:3000])
        if st >= 300: sys.exit(1)

    elif cmd == "query":
        st, out = call("POST", f"/v1/projects/{REF}/database/query", token, {"query": sys.argv[2]})
        print(f"HTTP {st}"); print(out[:2000])
        if st >= 300: sys.exit(1)

if __name__ == "__main__":
    main()
