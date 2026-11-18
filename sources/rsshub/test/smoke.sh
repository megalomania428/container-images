#!/usr/bin/env bash
# cspell:ignore graphql healthz
# Smoke test of the rsshub image: the GitHub releases route reads a GraphQL mock that the
# same image runs on an internal Podman network without a way out.
set -ueo pipefail
[[ $# -eq 1 ]] || {
  echo "usage: $0 IMAGE" >&2
  exit 2
}
image="$1"
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
suffix="$(printf '%04x%04x' "${RANDOM}" "${RANDOM}")"
network="rsshub-smoke-${suffix}"
mock="rsshub-smoke-mock-${suffix}"
app="rsshub-smoke-app-${suffix}"
token="smoke-token-${suffix}"
loopback='127.0.0.1' # DevSkim: ignore DS162092
cleanup() {
  local result=$?
  trap - EXIT
  set +e
  if [[ ${result} -ne 0 ]]; then
    echo '--- rsshub log ---'
    podman logs "${app}" 2>&1 | tail -n 50
    echo '--- mock log ---'
    podman logs "${mock}" 2>&1 | tail -n 20
  fi
  podman rm -f -t 0 "${app}" "${mock}" >/dev/null 2>&1
  podman network rm -f "${network}" >/dev/null 2>&1
  exit "${result}"
}
trap cleanup EXIT
podman network create --internal "${network}" >/dev/null
podman create --http-proxy=false --name "${mock}" --network "${network}" \
  --env MOCK_TOKEN="${token}" --entrypoint node "${image}" \
  /tmp/graphql-mock.mjs >/dev/null
podman cp "${script_dir}/graphql-mock.mjs" "${mock}:/tmp/graphql-mock.mjs"
podman start "${mock}" >/dev/null
mock_ip="$(podman inspect --format \
  "{{ (index .NetworkSettings.Networks \"${network}\").IPAddress }}" "${mock}")"
[[ -n ${mock_ip} ]] || {
  echo 'the mock has no address on the test network' >&2
  exit 1
}
mock_url="http://${mock_ip}:8080" # DevSkim: ignore DS137138
podman run -d --http-proxy=false --name "${app}" --network "${network}" \
  --env GITHUB_ACCESS_TOKEN="${token}" \
  --env GITHUB_RELEASES_GRAPHQL_URL="${mock_url}/graphql" \
  --env GITHUB_RELEASES_MIN_AGE=0 --env GITHUB_RELEASES_RESPONSE_TIMEOUT=30 \
  "${image}" >/dev/null
app_url="http://${loopback}:1200" # DevSkim: ignore DS137138
ready=0
for _ in {1..90}; do
  if podman exec "${app}" curl -fsS --max-time 5 "${app_url}/healthz" \
    >/dev/null 2>&1; then
    ready=1
    break
  fi
  sleep 1
done
[[ ${ready} -eq 1 ]] || {
  echo 'rsshub did not become ready' >&2
  exit 1
}
# Prints the body of a route response and its HTTP status on the last line.
fetch_route() {
  podman exec "${app}" curl -sS --max-time 60 -w '\n%{http_code}' "${app_url}$1"
}
# Checks the status of a route response and every given substring of its body.
check_route() {
  local path="$1" status="$2" body code needle
  shift 2
  body="$(fetch_route "${path}")"
  code="${body##*$'\n'}"
  [[ ${code} == "${status}" ]] || {
    echo "${path}: HTTP ${code}, expected ${status}" >&2
    exit 1
  }
  for needle in "$@"; do
    grep -qF -- "${needle}" <<<"${body}" || {
      echo "${path}: the response lacks ${needle}" >&2
      exit 1
    }
  done
  echo "PASS ${path}"
}
mock_posts() {
  podman exec "${app}" curl -fsS --max-time 10 "${mock_url}/count"
}
check_route '/github/releases/org/smoke-org' 200 'smoke-org/demo v1.0.0 (Smoke module)' \
  'RE_smoke#r1' 'releases/download/v1.0.0/demo.apk' 'demo-debug.apk'
posts="$(mock_posts)"
check_route '/github/releases/org/Smoke-Org?limit=1' 200 'RE_smoke#r1'
check_route '/github/releases/org/smoke-org?format=json' 200 'smoke-org/demo'
[[ $(mock_posts) == "${posts}" ]] || {
  echo 'a fresh feed started another crawl' >&2
  exit 1
}
check_route '/github/releases/user/smoke-org' 200 'smoke-org/demo v1.0.0' 'RE_smoke#r1'
check_route '/github/releases/repo/smoke-org/demo' 200 'RE_smoke#r1'
check_route '/github/releases/org/smoke-org?release_type=draft' 503 'release_type'
echo 'rsshub smoke test passed'
