#!/usr/bin/env bash
# hawkbit.sh — drive the local hawkBit server for RAUC bundle distribution.
#
# Server lifecycle + a thin wrapper around the hawkBit Management REST API
# to: register a target, upload a .raucb as a software module, wrap it in a
# distribution set, and assign it to a target (forced rollout). The device
# (rauc-hawkbit-updater) then polls the DDI API, downloads and installs it.
# `wait`/`verify` are CI-oriented gates (REST-poll readiness / rollout
# outcome); `target`/`push`/`deploy` are idempotent by controllerId /
# name+version so pipeline reruns don't accumulate duplicate server-side
# objects.
#
# Requires: docker compose, curl, jq.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$DIR"

HB_URL="${HB_URL:-http://localhost:8090}"        # Management + DDI base URL
HB_AUTH="${HB_AUTH:-admin:admin}"                # Management REST basic auth
API="$HB_URL/rest/v1"
SM_TYPE="${SM_TYPE:-os}"                          # software module type key
DS_TYPE="${DS_TYPE:-os}"                          # distribution set type key

say(){ echo "hawkbit: $*" >&2; }
die(){ echo "hawkbit: $*" >&2; exit 1; }
req(){ curl -fsSL -u "$HB_AUTH" -H "Accept: application/json" "$@"; }

# req_code <curl-args...>  -> sets REQ_CODE (http status, "000" on a connection
# failure) and REQ_BODY. Never fails itself (no -f) so callers can branch on
# status instead of only getting a bare curl error.
req_code(){
  local tmp; tmp="$(mktemp)"
  REQ_CODE="$(curl -sS -o "$tmp" -w '%{http_code}' -u "$HB_AUTH" -H "Accept: application/json" "$@" || echo 000)"
  REQ_BODY="$(cat "$tmp" 2>/dev/null || true)"
  rm -f "$tmp"
}

need(){
  command -v docker >/dev/null 2>&1 || die "missing dependency: docker"
  docker compose version >/dev/null 2>&1 || die "missing dependency: docker compose plugin"
  command -v curl >/dev/null 2>&1 || die "missing dependency: curl"
  command -v jq >/dev/null 2>&1 || die "missing dependency: jq (install with e.g. 'apt install jq')"
}

cmd_up(){
  docker compose up -d
  say "UI http://localhost:8088 (login: see HB_AUTH, default admin:admin) · REST/DDI $HB_URL — run '$0 wait' before first REST use"
}
cmd_down(){ docker compose down; }               # keeps volumes (persistent)
cmd_status(){ docker compose ps; }

# logs [svc] [--once]   (default svc=hawkbit; --once = one-shot dump, no -f)
cmd_logs(){
  local svc="hawkbit" once=0 a
  for a in "$@"; do
    case "$a" in
      --once) once=1 ;;
      *)      svc="$a" ;;
    esac
  done
  if [ "$once" = 1 ]; then docker compose logs "$svc"; else docker compose logs -f "$svc"; fi
}

# wait [timeout-seconds]   -> block until the Management REST API responds.
# Deliberately a REST poll, not a `docker compose` healthcheck: compose.yaml
# has no healthcheck on the hawkbit service itself (upstream-verbatim except
# the postgres volume), and a successful authenticated REST call is a
# strictly stronger readiness signal anyway (proves migration finished, the
# app is serving, and HB_URL/HB_AUTH are correct).
cmd_wait(){
  local timeout="${1:-120}" start now
  start=$(date +%s)
  while true; do
    if req "$API/targets?limit=1" >/dev/null 2>&1; then
      now=$(date +%s)
      echo "OK hawkbit=ready ($((now - start))s)"
      return 0
    fi
    now=$(date +%s)
    if [ $((now - start)) -ge "$timeout" ]; then
      echo "FAIL hawkbit=not-ready after ${timeout}s" >&2
      return 1
    fi
    sleep 3
  done
}

# target <controllerId> [securityToken]   -> idempotent: GET first, reuse the
# server's own stored token if the target already exists (never mints and
# prints an unused token when the create branch wasn't actually taken).
cmd_target(){
  local id="${1:?usage: target <controllerId> [token]}"; local tok="${2:-}"
  req_code "$API/targets/$id"
  case "$REQ_CODE" in
    200)
      tok="$(printf '%s' "$REQ_BODY" | jq -r '.securityToken // empty')"
      [ -n "$tok" ] || die "target '$id' exists but the response had no securityToken (HTTP 200): $REQ_BODY"
      say "target '$id' exists — reusing its stored token"
      ;;
    404)
      # Read a fixed amount first so no pipe element closes early (SIGPIPE would
      # trip pipefail and abort under set -e).
      [ -n "$tok" ] || tok="$(head -c 48 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | cut -c1-32)"
      req_code -X POST "$API/targets" -H "Content-Type: application/json" \
        -d "[{\"controllerId\":\"$id\",\"name\":\"$id\",\"securityToken\":\"$tok\"}]"
      case "$REQ_CODE" in
        200|201) say "target '$id' created" ;;
        *)       die "target create failed (HTTP $REQ_CODE): $REQ_BODY" ;;
      esac
      ;;
    *) die "target lookup failed (HTTP $REQ_CODE): $REQ_BODY" ;;
  esac
  say "config.conf -> target_name=$id  auth_token=$tok"
  echo "$tok"
}

# push <bundle.raucb> [version]   -> prints the distribution-set id on stdout
# Idempotent by name+version: an existing software module / distribution set
# is reused rather than duplicated. CI callers should pass an explicit
# version; the default timestamp version intentionally stays non-idempotent,
# for interactive one-offs.
cmd_push(){
  local bundle="${1:?usage: push <bundle.raucb> [version]}"
  local ver="${2:-$(date +%Y%m%d-%H%M%S)}"
  [ -f "$bundle" ] || die "no such file: $bundle"
  local name; name="$(basename "$bundle" .raucb)"

  local sm
  sm="$(req "$API/softwaremodules?q=name==$name;version==$ver" | jq -r '.content[0].id // empty')"
  if [ -n "$sm" ]; then
    say "software module '$name' $ver exists (id=$sm) — reusing"
  else
    req_code -X POST "$API/softwaremodules" -H "Content-Type: application/json" \
        -d "[{\"name\":\"$name\",\"version\":\"$ver\",\"type\":\"$SM_TYPE\"}]"
    case "$REQ_CODE" in
      200|201) sm="$(printf '%s' "$REQ_BODY" | jq -r '.[0].id // empty')" ;;
      *)       die "software module create failed (HTTP $REQ_CODE): $REQ_BODY" ;;
    esac
    [ -n "$sm" ] || die "software module create failed: no id in response ($REQ_BODY)"
    req_code -X POST "$API/softwaremodules/$sm/artifacts" -F "file=@$bundle"
    case "$REQ_CODE" in
      200|201) : ;;
      *)       die "artifact upload failed (HTTP $REQ_CODE): $REQ_BODY" ;;
    esac
  fi

  local ds
  ds="$(req "$API/distributionsets?q=name==$name;version==$ver" | jq -r '.content[0].id // empty')"
  if [ -n "$ds" ]; then
    say "distribution set '$name' $ver exists (id=$ds) — reusing"
  else
    req_code -X POST "$API/distributionsets" -H "Content-Type: application/json" \
        -d "[{\"name\":\"$name\",\"version\":\"$ver\",\"type\":\"$DS_TYPE\",\"modules\":[{\"id\":$sm}]}]"
    case "$REQ_CODE" in
      200|201) ds="$(printf '%s' "$REQ_BODY" | jq -r '.[0].id // empty')" ;;
      *)       die "distribution set create failed (HTTP $REQ_CODE): $REQ_BODY" ;;
    esac
    [ -n "$ds" ] || die "distribution set create failed: no id in response ($REQ_BODY)"
  fi

  say "$(basename "$bundle") (module=$sm) -> distribution set $ds (version $ver)"
  echo "$ds"
}

# assign <ds-id> <controllerId>
# Returns non-zero (does not die) on failure so cmd_deploy can add its own
# retry-hint context; a standalone `assign` call still exits non-zero via
# `set -e` since this is the last command in its case branch.
cmd_assign(){
  local ds="${1:?usage: assign <ds-id> <controllerId>}"; local id="${2:?controllerId}"
  req_code -X POST "$API/distributionsets/$ds/assignedTargets" -H "Content-Type: application/json" \
    -d "[{\"id\":\"$id\",\"type\":\"forced\"}]"
  case "$REQ_CODE" in
    200|201) : ;;
    *)       say "assign failed (HTTP $REQ_CODE): $REQ_BODY"; return 1 ;;
  esac
  local assigned already
  assigned="$(printf '%s' "$REQ_BODY" | jq -r '.assigned // 0')"
  already="$(printf '%s' "$REQ_BODY" | jq -r '.alreadyAssigned // 0')"
  # hawkBit's assignedTargets endpoint accepts an unknown controllerId
  # silently (HTTP 200, zero effect) rather than erroring — a typo'd
  # target id would otherwise report false success.
  if [ "$assigned" = 0 ] && [ "$already" = 0 ]; then
    say "assign reported zero effect (assigned=0 alreadyAssigned=0) — target '$id' likely doesn't exist"
    return 1
  fi
  say "assigned distribution set $ds -> target $id (forced) — assigned=$assigned alreadyAssigned=$already"
}

# deploy <bundle.raucb> <controllerId> [version]   (push + assign)
cmd_deploy(){
  local bundle="${1:?usage: deploy <bundle.raucb> <controllerId> [version]}"
  local id="${2:?controllerId}"; local ver="${3:-}"
  local ds; ds="$(cmd_push "$bundle" "$ver")"
  cmd_assign "$ds" "$id" \
    || die "assign failed after push succeeded — distribution set $ds is uploaded; retry with: $0 assign $ds $id"
}

# verify <controllerId> [timeout-seconds]   -> poll the latest rollout action
# to a terminal state. Pure REST, no SSH to the device needed. `status` is
# the only action-level state field hawkBit exposes (no separate
# "detailStatus"); `active=false` distinguishes "settled" from "still in
# progress".
cmd_verify(){
  local id="${1:?usage: verify <controllerId> [timeout-seconds]}"
  local timeout="${2:-600}" start now body aid status active
  start=$(date +%s)
  while true; do
    body="$(req "$API/targets/$id/actions?limit=1&sort=id:DESC" 2>/dev/null || echo '{}')"
    aid="$(printf '%s' "$body" | jq -r '.content[0].id // empty')"
    status="$(printf '%s' "$body" | jq -r '.content[0].status // empty')"
    # No `// empty` here: jq's `//` treats a genuine `false` as falsy too, so
    # it would discard the very value (active=false, i.e. "settled") this
    # check exists to detect. `.content[0].active` alone prints "null" when
    # there's no action at all, which the `[ -n "$aid" ]` guard already
    # covers.
    active="$(printf '%s' "$body" | jq -r '.content[0].active')"
    if [ -n "$aid" ] && [ "$status" = finished ] && [ "$active" = false ]; then
      echo "OK action=$aid status=finished"
      return 0
    fi
    if [ -n "$aid" ] && [ "$status" = error ]; then
      echo "FAIL action=$aid status=error" >&2
      return 1
    fi
    now=$(date +%s)
    if [ $((now - start)) -ge "$timeout" ]; then
      echo "FAIL action=${aid:-none} status=${status:-none} after ${timeout}s (timeout)" >&2
      return 1
    fi
    sleep 5
  done
}

usage(){
  cat >&2 <<EOF
Usage: $0 <command>
  up | down | status | logs [svc] [--once]  server lifecycle (down keeps the volumes)
  wait   [timeout-s]                  block until the REST API responds (default 120s)
  target <id> [token]                 register a target (idempotent); prints its auth_token
  push   <bundle.raucb> [ver]         upload bundle (idempotent by name+ver); prints distribution-set id
  assign <ds-id> <id>                 assign a distribution set to a target (forced)
  deploy <bundle.raucb> <id> [ver]    push + assign in one step
  verify <id> [timeout-s]             poll the latest rollout to a terminal state (default 600s)

Env: HB_URL=$HB_URL  HB_AUTH=<user:pass> (default admin:admin)  SM_TYPE=os  DS_TYPE=os
EOF
  return 2
}

# Skip dispatch when sourced as a library by the self-test.
if [ "${HAWKBIT_SH_LIB:-}" != 1 ]; then

_cmd="${1:-}"
case "$_cmd" in
  # usage() returns 2; the help path must not let that trip `set -e` before
  # reaching its own `exit 0`. Bare "" (no args at all) is deliberately NOT
  # folded into this branch — it exits 2 below, like an unknown subcommand.
  help|-h|--help) usage || true; exit 0 ;;
  "")             usage ;;
esac

need

case "$_cmd" in
  up)     cmd_up ;;
  down)   cmd_down ;;
  status) cmd_status ;;
  logs)   shift; cmd_logs "$@" ;;
  wait)   shift; cmd_wait "$@" ;;
  target) shift; cmd_target "$@" ;;
  push)   shift; cmd_push "$@" ;;
  assign) shift; cmd_assign "$@" ;;
  deploy) shift; cmd_deploy "$@" ;;
  verify) shift; cmd_verify "$@" ;;
  *)      say "unknown subcommand: $_cmd"; usage ;;
esac

fi
