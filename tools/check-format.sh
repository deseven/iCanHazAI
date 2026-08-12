#!/bin/zsh
#
# Checks that Swift and TypeScript sources are correctly formatted. Used by
# the git pre-commit hook; can also be run manually.
#
#   ./tools/check-format.sh             # check all files in the repo
#   ./tools/check-format.sh --staged    # check only staged files
#   ./tools/check-format.sh --changed   # check staged + unstaged (working tree)
#   ./tools/check-format.sh --fix       # format all files in place
#   ./tools/check-format.sh --staged-fix # format staged files in place and re-stage
#
# Exits non-zero if any checked file is not formatted.

set -uo pipefail

loc="$(cd "$(dirname "${(%):-%x}")/.." && pwd)"
cd "$loc"

mode="all"
[ "${1:-}" = "--staged" ] && mode="staged"
[ "${1:-}" = "--changed" ] && mode="changed"
[ "${1:-}" = "--fix" ] && mode="fix"
[ "${1:-}" = "--staged-fix" ] && mode="staged-fix"

fail=0

# ── Resolve files to check ────────────────────────────────────────────

swift_files=()
ts_files=()

if [ "$mode" = "fix" ]; then
    while IFS= read -r f; do swift_files+=("$f"); done < <(find src tests shared -name '*.swift' -type f)
    while IFS= read -r f; do ts_files+=("$f"); done < <(find chatrenderer/src chatrenderer/tests \( -name '*.ts' -o -name '*.tsx' \) -type f)
else
    if [ "$mode" = "staged" ] || [ "$mode" = "staged-fix" ]; then
        base="--cached"
    else
        base="HEAD"
    fi
    while IFS= read -r f; do
        case "$f" in
            *.swift) swift_files+=("$f") ;;
            chatrenderer/src/*.ts|chatrenderer/src/*.tsx|chatrenderer/tests/*.ts|chatrenderer/tests/*.tsx) ts_files+=("$f") ;;
        esac
    done < <(git diff --name-only --diff-filter=ACM $base)
fi

# ── Swift ─────────────────────────────────────────────────────────────

if [ ${#swift_files[@]} -gt 0 ]; then
    if ! command -v xcrun >/dev/null 2>&1 || ! xcrun --find swift-format >/dev/null 2>&1; then
        echo "error: swift-format not found (install Xcode or the Swift toolchain)" >&2
        exit 1
    fi

    case "$mode" in
        fix)
            xcrun swift-format format --in-place --recursive \
                --configuration "$loc/.swift-format" src tests shared
            echo "swift-format: formatted ${#swift_files[@]} files"
            ;;
        staged-fix)
            for f in "${swift_files[@]}"; do
                xcrun swift-format format --in-place --configuration "$loc/.swift-format" "$f" 2>/dev/null
            done
            ;;
        *)
            for f in "${swift_files[@]}"; do
                if ! xcrun swift-format format --configuration "$loc/.swift-format" "$f" 2>/dev/null | diff -q "$f" - >/dev/null; then
                    echo "not formatted: $f"
                    fail=1
                fi
            done
            ;;
    esac
fi

# ── TypeScript ────────────────────────────────────────────────────────

if [ ${#ts_files[@]} -gt 0 ]; then
    if ! command -v node >/dev/null 2>&1 || [ ! -x "$loc/chatrenderer/node_modules/.bin/prettier" ]; then
        echo "error: prettier not installed — run 'npm install' in chatrenderer/" >&2
        exit 1
    fi

    prettier=(node "$loc/chatrenderer/node_modules/.bin/prettier" --config "$loc/chatrenderer/.prettierrc.json")

    case "$mode" in
        fix|staged-fix)
            "${prettier[@]}" --write "${ts_files[@]}" >/dev/null
            ;;
        *)
            for f in "${ts_files[@]}"; do
                if ! "${prettier[@]}" --check "$f" >/dev/null 2>&1; then
                    echo "not formatted: $f"
                    fail=1
                fi
            done
            ;;
    esac
fi

# Re-stage files that were formatted in place so the fixes are committed.
if [ "$mode" = "staged-fix" ]; then
    if [ ${#swift_files[@]} -gt 0 ]; then
        git add -- "${swift_files[@]}"
    fi
    if [ ${#ts_files[@]} -gt 0 ]; then
        git add -- "${ts_files[@]}"
    fi
fi

exit $fail
