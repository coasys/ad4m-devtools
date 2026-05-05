#!/usr/bin/env bash
# ad4m-type-check.sh — Verify ts-rs generated types match SDK expectations
# Usage: ad4m-type-check.sh [--repo ./ad4m]
set -euo pipefail

REPO="${1:-./ad4m}"

echo "═══════════════════════════════════════════════════════════════════"
echo "  AD4M Type Coverage Check"
echo "  Repo: $REPO"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

# Step 1: Generate ts-rs bindings
echo "── Step 1: Generate ts-rs bindings ──"
cd "$REPO/rust-executor"
if cargo test export_ts_bindings 2>&1 | tail -5; then
  echo "✅ ts-rs bindings generated"
else
  echo "❌ ts-rs binding generation failed"
  exit 1
fi

# Step 2: Check generated files exist
echo ""
echo "── Step 2: Check generated type files ──"
GEN_DIR="$REPO/core/src/generated/rest"
if [[ -d "$GEN_DIR" ]]; then
  COUNT=$(find "$GEN_DIR" -name "*.ts" | wc -l | tr -d ' ')
  echo "✅ Found $COUNT generated type files in $GEN_DIR"
  ls "$GEN_DIR"/*.ts 2>/dev/null | head -20
else
  echo "⚠️  No generated/rest directory found at $GEN_DIR"
  echo "   Checking alternative locations..."
  find "$REPO" -path "*/generated*" -name "*.ts" | head -10
fi

# Step 3: TypeScript compilation check
echo ""
echo "── Step 3: SDK TypeScript compilation ──"
cd "$REPO/core"
if pnpm exec tsc --noEmit 2>&1 | tail -10; then
  echo "✅ SDK compiles clean"
else
  echo "❌ SDK has type errors (see above)"
fi

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "  Done"
echo "═══════════════════════════════════════════════════════════════════"
