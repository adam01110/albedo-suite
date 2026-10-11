#!/usr/bin/env bash

if [[ "$#" -ne 1 ]]; then
  echo 'usage: albedo-mcp-launcher CONFIG.json' >&2
  exit 2
fi
config=$1

# Reject malformed launch metadata before reading credentials.
jq -e -s --from-file "@launchConfig@" "$config" >/dev/null

runtime_path=$(jq -r '.runtimePath' "$config")
base_path=$(jq -r '.environment.PATH // env.PATH' "$config")
assignments=("PATH=$runtime_path:$base_path")

while IFS= read -r -d "" name && IFS= read -r -d "" value; do
  assignments+=("$name=$value")
done < <(jq -j '.environment | del(.PATH) | to_entries[] | .key, "\u0000", .value, "\u0000"' "$config")

# Secret values override public environment, but never affect this parser.
while IFS= read -r -d "" name && IFS= read -r -d "" path; do
  value=$(< "$path")
  assignments+=("$name=$value")
done < <(jq -j '.secrets | to_entries[] | .key, "\u0000", .value, "\u0000"' "$config")

mapfile -d "" -t command < <(jq -j '.command, "\u0000", (.args[] | ., "\u0000")' "$config")
if [[ "${#command[@]}" -eq 0 ]]; then
  echo 'missing MCP command' >&2
  exit 1
fi

# Apply environment only after parsing, avoiding collisions with shell locals.
exec @env@ -- "${assignments[@]}" "${command[@]}"
