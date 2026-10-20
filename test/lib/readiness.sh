#!/usr/bin/env bash
# readiness.sh - shared readiness probes for the end-to-end harnesses.
#
# Sourced by run-tests.sh and run-phase1.sh so the two cannot drift apart on what "ready" means. They
# did drift, and it cost an hour per run: run-tests.sh waited for HTTP 200 on /api/rag/health while
# run-phase1.sh waited for the payload's status to be UP. That endpoint answers
# `200 {"status":"DOWN"}` while its dependencies are still starting (see SemanticSearchController.health),
# so the 200 check returned immediately and the Alfresco suite began against a service that was not
# serving. The B-series then failed on documents the ingester had never discovered, which reads as a
# code regression and is not one. See AlfrescoLabs/content-lake-app-deployment#20.
#
# Callers must have CURL_TLS set ("-k" when the proxy terminates TLS with a self-signed certificate).

# wait_http_code <url> <expected_code> [auth] [max_tries=60] [interval_s=10]
#
# For an endpoint whose status code is the whole signal: a repository API, a sync API behind nginx.
wait_http_code() {
  local url="$1" want="$2" auth="${3:-}" max="${4:-60}" interval="${5:-10}"
  local curl_auth=(); [ -n "$auth" ] && curl_auth=(-u "$auth")
  local i code
  for i in $(seq 1 "$max"); do
    # shellcheck disable=SC2086
    code=$(curl -s $CURL_TLS -o /dev/null -w '%{http_code}' "${curl_auth[@]}" "$url" 2>/dev/null || echo 000)
    [ "$code" = "$want" ] && return 0
    printf '.'; sleep "$interval"
  done
  echo; return 1
}

# wait_json_field <url> <jq_filter> <expected> [max_tries=60] [interval_s=10] [auth]
#
# For an endpoint that reports its own health in the body. Use this, not a status-code check, whenever
# the endpoint answers 200 while unhealthy.
#
# Pass auth whenever the body depends on it. /api/rag/health is reachable unauthenticated but its
# embedding and hxpr probes are not: without credentials they report DOWN with "No authenticated
# principal is present", so the endpoint answers DEGRADED for ever and a wait on it can only time out.
wait_json_field() {
  local url="$1" filter="$2" want="$3" max="${4:-60}" interval="${5:-10}" auth="${6:-}"
  local curl_auth=(); [ -n "$auth" ] && curl_auth=(-u "$auth")
  local i val
  for i in $(seq 1 "$max"); do
    # shellcheck disable=SC2086
    val=$(curl -s $CURL_TLS "${curl_auth[@]}" "$url" 2>/dev/null | jq -r "$filter" 2>/dev/null || echo "")
    [ "$val" = "$want" ] && return 0
    printf '.'; sleep "$interval"
  done
  echo; return 1
}

# wait_rag_up <base_url> [auth=admin:admin] [max_tries=60] [interval_s=5]
#
# The one probe both harnesses got wrong, in two ways: they waited on the status code, which is always
# 200, and they sent no credentials, so the body reported DEGRADED whatever the service was doing. A
# gate that can only time out is not a gate; it is a five-minute sleep that happens to help.
wait_rag_up() {
  local base="$1" auth="${2:-admin:admin}" max="${3:-60}" interval="${4:-5}"
  if wait_json_field "${base}/api/rag/health" '.status' 'UP' "$max" "$interval" "$auth"; then
    return 0
  fi
  echo
  echo "RAG health never reached UP. Current payload:"
  # shellcheck disable=SC2086
  curl -s $CURL_TLS -u "$auth" "${base}/api/rag/health" 2>/dev/null | jq . 2>/dev/null || true
  echo "rag-service recent logs:"
  docker logs --tail 60 content-lake-app-rag-service-1 2>&1 | tail -60 || true
  return 1
}
