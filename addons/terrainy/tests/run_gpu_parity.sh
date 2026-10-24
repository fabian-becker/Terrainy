#!/usr/bin/env bash
# Terrainy 2 GPU parity suite (tested contract, not gated in CI: needs a RenderingDevice).
# Runs the whole suite WITHOUT --headless so the GPU cases execute instead of skipping, and
# fails when any GPU case skipped (a silent skip is never a pass).
#
#   GODOT=/path/to/godot addons/terrainy/tests/run_gpu_parity.sh
set -euo pipefail
GODOT="${GODOT:-godot}"
cd "$(dirname "$0")/../../.."
out="$(mktemp)"
"$GODOT" --path . --script res://addons/terrainy/tests/run_tests.gd 2>&1 | tee "$out"
if grep -q "SKIP  test_gpu_parity" "$out"; then
	echo "GPU parity cases skipped: no RenderingDevice on this machine" >&2
	exit 2
fi
grep -q "result:  PASS" "$out"
