#!/usr/bin/env bash

home="$1"
target="${3:-extensions.json}"
case "$target" in
  extensions.json|config.json|capabilities.json) ;;
  *) echo "Unsupported Albedo settings document" >&2; exit 1 ;;
esac

umask 077
mkdir -p "$home"
temporary=""

# Hold the daemon's SQLite lock until settings publication finishes.
coproc sqlite3 -batch -bail "$home/daemon.lock"
lock_pid=$!
exec {lock_input}>&"${COPROC[1]}"
exec {lock_output}<&"${COPROC[0]}"

cleanup() {
  rm -f "$temporary"
  kill "$lock_pid" 2>/dev/null || true
  wait "$lock_pid" 2>/dev/null || true
}
trap cleanup EXIT

printf 'BEGIN EXCLUSIVE;\nSELECT 1;\n' >&"$lock_input"
if ! read -r acquired <&"$lock_output" || [[ "$acquired" != 1 ]]; then
  echo "Stop the Albedo daemon before applying settings" >&2
  exit 1
fi
if [[ -e "$home/.settings-recovery" ]]; then
  echo "Let Albedo recover its settings journal before applying defaults" >&2
  exit 1
fi

temporary=$(mktemp "$home/.settings-XXXXXX")
input=(--argjson initial false "$home/$target")
if [[ ! -e "$home/$target" ]]; then
  input=(--argjson initial true /dev/null)
fi
jq --exit-status --slurp --arg target "$target" --slurpfile defaults "$2" \
  --from-file "@mergeSettings@" "${input[@]}" > "$temporary"

if [[ -e "$home/$target" ]] && cmp -s "$temporary" "$home/$target"; then
  exit 0
fi
mv -f "$temporary" "$home/$target"
