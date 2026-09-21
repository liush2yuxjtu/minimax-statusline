#!/usr/bin/env bats
#
# tests/test_statusline.bats — shell-level tests for minimax-statusline.sh.
# Run with:   bats tests/
# (bats-core from https://github.com/bats-core/bats-core)

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  SCRIPT="$REPO_ROOT/minimax-statusline.sh"
  FIXTURE="$REPO_ROOT/tests/fixtures/basic.json"
  export NO_COLOR=1    # strip colors so byte-comparisons are stable
  export STATUSLINE_THEME="minimal"  # use the minimal theme (no colors)
  export STATUSLINE_CACHE_DIR="$BATS_TMPDIR/cache"
  rm -rf "$STATUSLINE_CACHE_DIR"
  mkdir -p "$STATUSLINE_CACHE_DIR"
  export STATUSLINE_CONFIG="$STATUSLINE_CACHE_DIR/base.toml"
  printf '[provider]\nname = "none"\n' > "$STATUSLINE_CONFIG"
  # Stub ANTHROPIC_AUTH_TOKEN to a fake value so the provider doesn't try
  # to talk to the real network (it'll fail, but that's fine — we just want
  # the script to render *something*).
  export ANTHROPIC_AUTH_TOKEN="test-token-no-network"
}

@test "statusline --version prints 0.2.1" {
  run "$SCRIPT" --version
  [ "$status" -eq 0 ]
  [[ "$output" == *"minimax-statusline 0.2.1"* ]]
}

@test "statusline --help mentions --doctor" {
  run "$SCRIPT" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"--doctor"* ]]
  [[ "$output" == *"--init-config"* ]]
}

@test "statusline --doctor lists python3" {
  run "$SCRIPT" --doctor
  [ "$status" -eq 0 ]
  [[ "$output" == *"python3"* ]]
}

@test "statusline --dump-config includes theme name" {
  run "$SCRIPT" --dump-config
  [ "$status" -eq 0 ]
  [[ "$output" == *"theme:"* ]]
  [[ "$output" == *"provider:"* ]]
}

@test "statusline --self-test renders a line from basic.json" {
  run "$SCRIPT" --self-test
  [ "$status" -eq 0 ]
  [[ "$output" == *"@ -"* ]]
  # Should mention the dir basename
  [[ "$output" == *"widget"* ]]
}

@test "statusline renders on stdin input" {
  run bash -c "cat $FIXTURE | $SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"widget"* ]]
  [[ "$output" == *"ctx:"* ]]
}

@test "NO_COLOR strips ANSI escape codes" {
  run bash -c "cat $FIXTURE | NO_COLOR=1 $SCRIPT"
  [ "$status" -eq 0 ]
  # No escape character in output
  [[ "$output" != *$'\033'* ]]
}

@test "garbage stdin does not crash" {
  run bash -c "echo 'this is not json' | $SCRIPT"
  # Exit 0 is the contract — a TUI crash is worse than a blank line.
  [ "$status" -eq 0 ]
}

@test "empty stdin does not crash" {
  run bash -c "echo '' | $SCRIPT"
  [ "$status" -eq 0 ]
}

@test "provider=none hides the 5h segment" {
  cat > "$STATUSLINE_CACHE_DIR/test-cfg.toml" <<'TOML'
[provider]
name = "none"

[display]
theme = "minimal"
TOML
  run bash -c "cat $FIXTURE | STATUSLINE_CONFIG=$STATUSLINE_CACHE_DIR/test-cfg.toml $SCRIPT"
  [ "$status" -eq 0 ]
  # 5h segment should NOT appear
  [[ "$output" != *"5h:"* ]]
  [[ "$output" == *"ctx:"* ]]
}

@test "layout reorder: dir-branch-effort-ctx (no five_hour)" {
  cat > "$STATUSLINE_CACHE_DIR/test-cfg.toml" <<'TOML'
[provider]
name = "none"

[display]
theme = "minimal"

layout = ["dir", "branch", "effort", "ctx"]
TOML
  run bash -c "cat $FIXTURE | STATUSLINE_CONFIG=$STATUSLINE_CACHE_DIR/test-cfg.toml $SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"widget"* ]]
  [[ "$output" == *"@ -"* ]]
  [[ "$output" == *"effort=high"* ]]
  [[ "$output" == *"ctx:"* ]]
  [[ "$output" != *"5h:"* ]]
}

@test "STATUSLINE_THEME overrides config theme" {
  cat > "$STATUSLINE_CACHE_DIR/test-cfg.toml" <<'TOML'
[display]
theme = "default"   # config says default

[provider]
name = "none"
TOML
  # Env says minimal
  run bash -c "cat $FIXTURE | STATUSLINE_CONFIG=$STATUSLINE_CACHE_DIR/test-cfg.toml STATUSLINE_THEME=minimal $SCRIPT"
  [ "$status" -eq 0 ]
  # minimal theme uses '@' for branch; fixture path is intentionally not a Git checkout.
  [[ "$output" == *"@ -"* ]]
}

@test "token-redaction: debug log does not contain the token" {
  export DEBUG_STATUSLINE=1
  export ANTHROPIC_AUTH_TOKEN="super-secret-must-not-leak-xyz"
  rm -f "$STATUSLINE_CACHE_DIR/debug.log"
  run bash -c "cat $FIXTURE | $SCRIPT"
  [ "$status" -eq 0 ]
  if [ -f "$STATUSLINE_CACHE_DIR/debug.log" ]; then
    ! grep -q "super-secret-must-not-leak-xyz" "$STATUSLINE_CACHE_DIR/debug.log"
  fi
}

@test "top-level layout overrides display layout" {
  cat > "$STATUSLINE_CONFIG" <<'TOML'
layout = ["ctx"]
[provider]
name = "none"
[display]
layout = ["dir", "branch"]
TOML
  run bash -c "cat $FIXTURE | $SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ctx:"* ]]
  [[ "$output" != *"widget"* ]]
  [[ "$output" != *"@ -"* ]]
}
