#!/usr/bin/env bash
# Paints a believable-looking session for the README recording. Prints an
# initial banner and then loops emitting periodic activity lines so each
# pane looks alive when the wall is captured.
set -u

name="${1:-home}"

ts() { printf '%(%H:%M:%S)T' -1; }
pick() { local arr=("$@"); printf '%s' "${arr[$((RANDOM % $#))]}"; }

banner() {
    printf '\033[1;36m%s\033[0m\n' "$1"
    printf '\033[2m%s\033[0m\n\n' "$2"
}

case "$name" in
api)
    banner "api server  ::  Express :3000" "tail -F /var/log/api.log"
    cat <<'EOF'
[12:01:14] GET  /v1/users/4821       200   18ms
[12:01:14] POST /v1/sessions         201   42ms
[12:01:15] GET  /v1/users/4821       200   11ms
[12:01:15] GET  /v1/orders?page=2    200   64ms
[12:01:16] POST /v1/payments/charge  200  318ms
EOF
    while :; do
        sleep $((RANDOM % 3 + 2))
        method=$(pick GET GET GET POST)
        path=$(pick /v1/users /v1/orders /v1/sessions /v1/products)
        printf '[%s] %-4s %s/%-6d 200  %3dms\n' \
            "$(ts)" "$method" "$path" "$((RANDOM % 9999))" "$((RANDOM % 200 + 10))"
    done
    ;;
worker)
    banner "background worker  ::  redis queue" "./worker --queue=default"
    cat <<'EOF'
[INFO] connected to redis://localhost:6379
[INFO] processing: SendWelcomeEmail#48201
[INFO] processing: ResizeAvatar#48202
[INFO] processing: SendDigest#48203
[INFO] queue: 1287 pending
EOF
    while :; do
        sleep $((RANDOM % 3 + 2))
        job=$(pick SendEmail ResizeAvatar SendDigest BillUser ReindexSearch)
        printf '[INFO] processing: %s#%d\n' "$job" "$((RANDOM % 99999))"
    done
    ;;
db-migrate)
    banner "db migration  ::  postgres" "psql -f migrations/0042_add_indexes.sql"
    cat <<'EOF'
BEGIN
CREATE INDEX
NOTICE:  index "idx_users_email" does not exist, skipping
DROP INDEX
CREATE INDEX CONCURRENTLY idx_users_email ON users (lower(email));
  ... building (372842 / 1840293 rows)
EOF
    pct=20
    while :; do
        sleep $((RANDOM % 3 + 2))
        pct=$((pct + RANDOM % 6 + 1))
        [[ $pct -gt 99 ]] && pct=99
        printf '  ... building (%d%% complete)\n' "$pct"
    done
    ;;
dev-server)
    banner "frontend dev server  ::  vite :5173" "npm run dev"
    cat <<'EOF'

  VITE v5.0.10  ready in 412 ms

  ➜  Local:   http://localhost:5173/
  ➜  Network: use --host to expose

12:01:18 [vite] hmr update /src/components/Header.tsx
12:01:22 [vite] hmr update /src/routes/dashboard.tsx
EOF
    while :; do
        sleep $((RANDOM % 3 + 3))
        f=$(pick Header.tsx Footer.tsx Sidebar.tsx dashboard.tsx login.tsx)
        printf '%s [vite] hmr update /src/%s\n' "$(ts)" "$f"
    done
    ;;
tests)
    banner "test runner  ::  vitest --watch" "watching for file changes…"
    cat <<'EOF'
 ✓ src/utils/parse.test.ts (12)
 ✓ src/api/users.test.ts (8)
 ✓ src/api/orders.test.ts (15)
 ✓ src/components/Header.test.tsx (4)

 Test Files  4 passed (4)
      Tests  39 passed (39)
   Start at  12:01:11
   Duration  1.42s
EOF
    while :; do
        sleep $((RANDOM % 5 + 4))
        f=$(pick parse.test.ts users.test.ts orders.test.ts Header.test.tsx)
        printf ' ✓ src/%s — re-run, %d passed\n' "$f" "$((RANDOM % 12 + 4))"
    done
    ;;
logs)
    banner "nginx access log  ::  tail -F" "/var/log/nginx/access.log"
    cat <<'EOF'
192.0.2.41 - - [07/May/2026:12:01:14 +0000] "GET /assets/app.css HTTP/1.1" 200 18472
192.0.2.41 - - [07/May/2026:12:01:14 +0000] "GET /assets/app.js HTTP/1.1" 200 284911
198.51.100.7 - - [07/May/2026:12:01:15 +0000] "GET /api/users/me HTTP/1.1" 200 482
203.0.113.18 - - [07/May/2026:12:01:15 +0000] "POST /api/login HTTP/1.1" 302 0
192.0.2.41 - - [07/May/2026:12:01:16 +0000] "GET /favicon.ico HTTP/1.1" 200 4286
EOF
    while :; do
        sleep $((RANDOM % 3 + 2))
        ip=$(pick "192.0.2.41" "198.51.100.7" "203.0.113.18" "198.51.100.99")
        path=$(pick /api/users/me /api/orders /assets/app.css /favicon.ico /api/feed)
        printf '%s - - [07/May/2026:%s +0000] "GET %s HTTP/1.1" 200 %d\n' \
            "$ip" "$(ts)" "$path" "$((RANDOM % 90000 + 200))"
    done
    ;;
notebook)
    banner "jupyter  ::  notebook kernel" "training a model"
    cat <<'EOF'
[I 12:01:11] Kernel started: 8e2a... (python3)
Epoch  1/20  loss=0.8421  acc=0.621
Epoch  2/20  loss=0.6128  acc=0.711
Epoch  3/20  loss=0.4892  acc=0.768
Epoch  4/20  loss=0.4011  acc=0.802
EOF
    epoch=5
    while :; do
        sleep $((RANDOM % 4 + 3))
        loss=$(awk -v e="$epoch" 'BEGIN{printf "%.4f", 0.4/(e/4 + 1)}')
        acc=$(awk -v e="$epoch" 'BEGIN{printf "%.3f", 0.80 + e*0.008}')
        printf 'Epoch %2d/20  loss=%s  acc=%s\n' "$epoch" "$loss" "$acc"
        epoch=$((epoch + 1))
        [[ $epoch -gt 20 ]] && epoch=5
    done
    ;;
agent)
    banner "agent  ::  long-running task" "claude --resume"
    cat <<'EOF'
> refactor the auth middleware to extract token validation
  into a separate module, and add tests covering the
  expired-token and malformed-header cases.

⏺ I'll start by reading the current middleware…
  Read auth/middleware.ts
  Read auth/middleware.test.ts
  Searching for token validation patterns…
EOF
    steps=("Edit auth/middleware.ts" \
        "Write auth/token.ts" \
        "Edit auth/middleware.test.ts" \
        "Bash npm test -- auth" \
        "Read auth/token.ts")
    while :; do
        sleep $((RANDOM % 4 + 3))
        s=$(pick "${steps[@]}")
        printf '  %s\n' "$s"
    done
    ;;
*)
    banner "$name" "(no fixture)"
    exec cat
    ;;
esac
