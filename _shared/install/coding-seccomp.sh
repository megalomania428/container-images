#!/usr/bin/env bash
set -euo pipefail
if (($# > 1)); then
  printf 'Usage: %s [profile.json]\n' "${0##*/}" >&2
  exit 2
fi
jq -s '
  if length != 1 then error("expected exactly one JSON profile") else .[0] end
  | if type != "object" then error("profile must be an object") else . end
  | if (.syscalls | type) != "array" then error("syscalls must be an array") else . end
  | if all(.syscalls[]; type == "object" and (.names | type == "array")
      and all(.names[]; type == "string")) then .
    else error("each syscall rule must have an array of names") end
  | .syscalls |= (map(.names |= map(select(. != "sethostname" and . != "setdomainname")))
      | map(select(.names | length > 0))
      + [{"names": ["sethostname", "setdomainname"], "action": "SCMP_ACT_ALLOW"}])
' -- "${@}"
