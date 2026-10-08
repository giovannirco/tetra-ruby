#!/bin/sh
# Contract test for any Tetra implementation (Go, Ruby, Node.js, TypeScript).
# Needs only POSIX sh and curl, so it runs from the curl image in Compose,
# from CI, or from a throwaway pod inside a cluster:
#
#   scripts/smoke.sh                      # http://localhost:8000
#   scripts/smoke.sh http://tetra.tetra.svc.cluster.local:8000
set -u

BASE="${1:-http://localhost:8000}"
BODY="$(mktemp)"
HEADERS="$(mktemp)"
trap 'rm -f "$BODY" "$HEADERS"' EXIT
pass=0
fail=0

# request METHOD PATH [extra curl args...] -> sets $status and $body
request() {
  method="$1"
  path="$2"
  shift 2
  status="$(curl -s -o "$BODY" -D "$HEADERS" -w '%{http_code}' -X "$method" "$@" "$BASE$path")" || status=000
  body="$(tr -d '\n' < "$BODY")"
}

ok() { pass=$((pass + 1)); printf '  ok    %s\n' "$1"; }
ko() { fail=$((fail + 1)); printf '  FAIL  %s\n        %s\n' "$1" "$2"; }

# expect NAME METHOD PATH STATUS EXACT_BODY
expect() {
  request "$2" "$3"
  if [ "$status" = "$4" ] && [ "$body" = "$5" ]; then ok "$1"; else ko "$1" "got $status $body, want $4 $5"; fi
}

# expect_has NAME METHOD PATH STATUS SUBSTRING
expect_has() {
  request "$2" "$3"
  case "$body" in
    *"$5"*) [ "$status" = "$4" ] && ok "$1" || ko "$1" "got status $status, want $4" ;;
    *) ko "$1" "status $status, body does not contain $5" ;;
  esac
}

echo "Tetra contract test against $BASE"

echo "arithmetic"
expect "sum"                      GET "/api/sum?term_one=4&term_two=1" 200 '{"result":5}'
expect "sub (spec example)"       GET "/api/sub?term_one=4&term_two=1" 200 '{"result":3}'
expect "mul"                      GET "/api/mul?term_one=6&term_two=7" 200 '{"result":42}'
expect "div"                      GET "/api/div?term_one=8&term_two=2" 200 '{"result":4}'
expect "div truncates"            GET "/api/div?term_one=7&term_two=2" 200 '{"result":3}'
expect "div truncates toward 0"   GET "/api/div?term_one=-7&term_two=2" 200 '{"result":-3}'
expect "signs"                    GET "/api/sum?term_one=-4&term_two=%2B10" 200 '{"result":6}'
expect "int64 max"                GET "/api/sum?term_one=9223372036854775806&term_two=1" 200 '{"result":9223372036854775807}'

echo "errors"
expect "division by zero"         GET "/api/div?term_one=1&term_two=0" 400 '{"error":"division by zero"}'
expect "overflow"                 GET "/api/mul?term_one=9223372036854775807&term_two=2" 400 '{"error":"result overflows a 64-bit integer"}'
expect "missing term_one"         GET "/api/sum?term_two=1" 400 '{"error":"missing query parameter term_one"}'
expect "missing term_two"         GET "/api/sum?term_one=1" 400 '{"error":"missing query parameter term_two"}'
expect "not an integer"           GET "/api/sum?term_one=abc&term_two=1" 400 '{"error":"term_one must be an integer, got \"abc\""}'
expect "decimal rejected"         GET "/api/sum?term_one=1&term_two=1.5" 400 '{"error":"term_two must be an integer, got \"1.5\""}'
expect "out of range"             GET "/api/sum?term_one=99999999999999999999&term_two=1" 400 '{"error":"term_one is outside the 64-bit integer range"}'
expect "unknown operation"        GET "/api/pow?term_one=2&term_two=8" 404 '{"error":"not found"}'
expect "wrong method"             POST "/api/sum?term_one=1&term_two=1" 405 '{"error":"method not allowed"}'

echo "operations"
expect "liveness"                 GET "/healthz" 200 '{"status":"ok"}'
expect "readiness"                GET "/readyz" 200 '{"status":"ready"}'
expect_has "catalogue"            GET "/api" 200 '"path":"/api/div"'
expect_has "version"              GET "/version" 200 '"implementation":'
expect_has "metrics: requests"    GET "/metrics" 200 'tetra_http_requests_total'
expect_has "metrics: outcomes"    GET "/metrics" 200 'tetra_calc_operations_total{'
expect_has "metrics: build info"  GET "/metrics" 200 'tetra_build_info{'
expect_has "web UI"               GET "/" 200 '<canvas id="scene"'

request GET "/healthz" -H "X-Request-Id: smoke-test-42"
if grep -qi '^x-request-id: smoke-test-42' "$HEADERS"; then ok "request id echoed"; else ko "request id echoed" "X-Request-Id not returned"; fi

request GET "/api/sum?term_one=1&term_two=1"
if grep -qi '^content-type: application/json' "$HEADERS"; then ok "json content type"; else ko "json content type" "$(grep -i '^content-type' "$HEADERS")"; fi

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
