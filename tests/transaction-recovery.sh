#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/helpers.sh"
trap cleanup_root EXIT
fresh_root
export SB_SERVICE_MODE=process
node=$("$CLI" add ss 28385 auto aes-256-gcm)
id=$(jq -r .id <<< "$node")
original=$(readlink "$SB_ROOT/current")
cp "$SB_ROOT/current/nodes/$id.json" "$SB_ROOT/run/original-node.json"
cat > "$SB_ROOT/run/paused-core" <<'CORE'
#!/usr/bin/env bash
set -Eeuo pipefail
if [[ ${1:-} == run ]] && jq -e 'any(.inbounds[];.listen_port==28386)' "$SB_ROOT/current/config.json" >/dev/null; then
    touch "$SB_ROOT/run/start-paused"
    exec sleep 60
fi
exec "$SB_REAL_CORE" "$@"
CORE
chmod +x "$SB_ROOT/run/paused-core"
# Kill the entire isolated apply process group after switching the pointer but
# before a new core starts. SIGKILL deliberately skips every shell rollback trap.
env SB_REAL_CORE="$SB_CORE" SB_CORE="$SB_ROOT/run/paused-core" setsid "$CLI" port "$id" 28386 >"$SB_ROOT/run/interrupted.log" 2>&1 &
apply_pid=$!
for ((i=0;i<100;i++)); do [[ ! -f $SB_ROOT/run/start-paused ]] || break; sleep .1; done
if (( i==100 )); then kill -KILL -- "-$apply_pid" 2>/dev/null || true; die '未进入预期的中断阶段'; fi
[[ $(readlink "$SB_ROOT/current") != "$original" ]]
jq -e '.phase=="applying"' "$SB_ROOT/transaction.json" >/dev/null
kill -KILL -- "-$apply_pid"
wait "$apply_pid" 2>/dev/null || true
"$CLI" status >"$SB_ROOT/run/recovered.json"
[[ $(readlink "$SB_ROOT/current") == "$original" ]]
cmp "$SB_ROOT/run/original-node.json" "$SB_ROOT/current/nodes/$id.json"
jq -e '.phase=="rolled-back"' "$SB_ROOT/transaction.json" >/dev/null
jq -e '.core_active==true' "$SB_ROOT/run/recovered.json" >/dev/null
port_is_listening 28385
! port_is_listening 28386
"$CLI" port "$id" 28387
port_is_listening 28387
pass 'SIGKILL after configuration switch recovers exact node, listeners and write lock on next command'
