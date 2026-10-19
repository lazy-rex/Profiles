#!/bin/sh
# Prepare an isolated lab for tests/profiles-lab.mjs and tests/profiles-plugin.mjs.
# Usage: tests/profiles-lab-setup.sh /tmp/rexlab-profiles-<you>
# It builds the hub and the renderer into the lab, writes init.lua, hub.json and profiles.json,
# and creates the Git fixture (repo on main, worktree repo-wt on feature, repo/sub/deeper).
# Then start the server and the hub as it prints. It starts nothing itself.
set -eu
L=${1:?lab directory, for example /tmp/rexlab-profiles-you}
case "$L" in /tmp/rexlab-profiles-*) ;; *) echo "refuse: use /tmp/rexlab-profiles-*" >&2; exit 1 ;; esac
W=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$L/int"
(cd "$W/hub" && go build -o "$L/hub" ./cmd/hub)
(cd "$W/view" && go build -o "$L/view" .)
printf '%s\n' '-- LAB config: load the generated palette commands.' 'pcall(require, "lazyrex_palette")' > "$L/init.lua"
cat > "$L/profiles.json" <<JSON
{"profiles": [
 {"id": "fake_claude", "name": "Fake Claude", "kind": "agent", "command": ["/bin/sh", "-c", "echo agent task=\$0; pwd; exec sleep 600", "\${task}"], "cwd": "$L/repo", "args": [{"name": "task", "label": "Task"}]},
 {"id": "logtail", "name": "Log tail", "kind": "accessory", "command": ["/bin/sh", "-c", "pwd; exec tail -f /dev/null"]}
]}
JSON
cat > "$L/hub.json" <<JSON
{"server": "unix://$L/rex.sock", "state": "$L/int", "view": "$L/view", "palette_lua": "$L/lazyrex_palette.lua",
 "agents": [{"id": "user", "name": "User", "status_record": ""}],
 "plugins": [{"name": "lazyrex", "path": "$W/plugins/lazyrex.lua"}, {"name": "profiles", "path": "$W/plugins/profiles.lua"}],
 "profiles": "$L/profiles.json"}
JSON
rm -rf "$L/repo" "$L/repo-wt"
mkdir -p "$L/repo/sub/deeper"
git -C "$L/repo" init -q -b main
git -C "$L/repo" -c user.name=lab -c user.email=lab@example.invalid commit -q --allow-empty -m init
git -C "$L/repo" worktree add -q -b feature "$L/repo-wt"
cat <<NEXT
Lab ready in $L. Start (each in its own terminal, or in the background):
  LAB_CONFIG=$L/init.lua $W/../lab/server.sh $L
  env -u REX_SESSION -u REX_BLOCK REX_SERVER=unix://$L/rex.sock $L/hub -config $L/hub.json
Then:
  PROFILES_LAB=$L node $W/tests/profiles-lab.mjs
  REX_SERVER=unix://$L/rex.sock PROFILES_LAB=$L node $W/tests/profiles-plugin.mjs
NEXT
