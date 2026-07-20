#!/bin/bash

set -euo pipefail

name="iCanHazAI"
shortName="ichai"
ident="wtf.d7.icanhazai"
loc="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
logFile="$loc/build.log"

if [ -f "$loc/.env" ]; then
    set -a
    source "$loc/.env"
    set +a
fi

bold='\033[1m'
dimColor='\033[2m'
greenColor='\033[32m'
redColor='\033[31m'
noColor='\033[0m'

cd "$loc"

# ── Determine build mode ─────────────────────────────────────────────
mode="dev"
case "${1:-}" in
    dev-release) mode="dev-release" ;;
    release)     mode="release" ;;
    clean)       mode="clean" ;;
    test)        mode="test" ;;
    *)           mode="dev" ;;
esac

buildConfig="release"; [ "$mode" = "dev" ] && buildConfig="debug"

# Dev builds a single arm64 slice straight into .build/arm64-apple-macosx;
# everything else builds a universal (arm64+x86_64) binary that SwiftPM
# lipo's automatically into .build/apple/Products.
if [ "$mode" = "dev" ]; then
    buildDir="$loc/.build/arm64-apple-macosx/$buildConfig"
else
    buildDir="$loc/.build/apple/Products/$buildConfig"
fi

# ── Determine signing & notarization ─────────────────────────────────
can_sign=false
can_notarize=false

if [ -n "${ICHAI_SIGNING_IDENTITY:-}" ] && [ "$mode" != "dev" ]; then
    can_sign=true
    if [ -n "${ICHAI_NOTARY_PROFILE:-}" ] || \
       { [ -n "${ICHAI_APPLE_ID:-}" ] && [ -n "${ICHAI_TEAM_ID:-}" ] && [ -n "${ICHAI_APP_PASSWORD:-}" ]; }; then
        can_notarize=true
    fi
fi

# ── Helpers ──────────────────────────────────────────────────────────

die() {
    echo -e "${redColor}[FAILED]${noColor}" > /dev/tty
    echo -e "  ${redColor}$1${noColor}" > /dev/tty
    echo -e "  ${dimColor}--- error output ---${noColor}" > /dev/tty
    tail -n +"$logMark" "$logFile" > /dev/tty 2>&1
    echo -e "  ${dimColor}--- end error output ---${noColor}" > /dev/tty
    exit 1
}

stepNum=0
totalSteps=0

step() {
    stepNum=$((stepNum + 1))
    printf "  ${dimColor}[%d/%d]${noColor} ${bold}%-36s${noColor} " "$stepNum" "$totalSteps" "$1"
}

ok() { echo -e "${greenColor}[OK]${noColor}"; }

# Steps are queued as tab-separated "label\terror\tfunc\targ" records; the
# pipeline runner executes them in order, so the total is always correct
# without manual step counting.
STEPS=()
add() {
    local label="$1" err="$2" func="$3" arg="${4:-}"
    STEPS+=("$(printf '%s\t%s\t%s\t%s' "$label" "$err" "$func" "$arg")")
}

run_pipeline() {
    totalSteps=${#STEPS[@]}
    for spec in "${STEPS[@]}"; do
        IFS=$'\t' read -r label err func arg <<< "$spec"
        step "$label"
        logMark=$(($(wc -l < "$logFile") + 1))
        {
            echo "--- $label ---"
            if [ -n "$arg" ]; then
                "$func" "$arg" || die "$err"
            else
                "$func" || die "$err"
            fi
        } >> "$logFile" 2>&1
        ok
    done
}

# ── Step functions ───────────────────────────────────────────────────

do_init_log() {
    echo "=== iCanHazAI build log ===" > "$logFile"
    echo "Date: $(date)" >> "$logFile"
    echo "Mode: $mode" >> "$logFile"
    echo "Signing: $can_sign" >> "$logFile"
    echo "Notarizing: $can_notarize" >> "$logFile"
    echo "" >> "$logFile"
}

do_clean_dist() {
    rm -rf "$loc/dist/$name.app" "$loc/dist/$shortName.zip" "$loc/dist/$shortName-dev.zip" \
           "$loc/dist/$shortName.dmg" "$loc/dist/$name"
    mkdir -p "$loc/dist"
}

do_resolve_deps() { swift package resolve; }

do_build_web() {
    cd "$loc/chatrenderer"
    npm install --no-audit --no-fund
    npm run build
    cd "$loc"
}

# One `swift build` builds the app. Dev = arm64 only; otherwise universal (arm64+x86_64).
do_build_swift() {
    if [ "$mode" = "dev" ]; then
        swift build -c "$buildConfig" --arch arm64
    else
        swift build -c "$buildConfig" --arch arm64 --arch x86_64
    fi
}

do_run_app_tests() { swift test --filter AllAppTests; }

do_clean_app_cache() {
    # Drop the SwiftData chat-metadata cache. The app self-heals an
    # incompatible cache on launch (ChatStore recreates it from disk), so this
    # is only a manual reset — wired to `./build.sh clean`, not every dev build
    # (wiping it every build defeated the cache, forcing a full re-scan each
    # startup).
    rm -rf "$HOME/iCanHazAI/.cache"
}

do_create_bundle() {
    local app="$loc/dist/$name.app"
    mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources/ChatRenderer" "$app/Contents/Resources/Default"

    cp "$buildDir/$name" "$app/Contents/MacOS/$name"
    cp "$loc/Info.plist" "$app/Contents/Info.plist"
    cp "$loc/res/main.icns" "$app/Contents/Resources/"
    cp -R "$loc/default/prompts" "$app/Contents/Resources/Default/prompts"
    cp -R "$loc/default/roles" "$app/Contents/Resources/Default/roles"
    cp "$loc/chatrenderer/dist/"* "$app/Contents/Resources/ChatRenderer/"
}

do_codesign() {
    local app="$loc/dist/$name.app"
    xattr -cr "$app"

    if [ "$can_sign" = true ]; then
        codesign --force --deep --sign "$ICHAI_SIGNING_IDENTITY" --options runtime --timestamp "$app"
    else
        codesign --force --deep --sign - -r="designated => identifier \"$ident\"" "$app"
    fi
}

do_create_zip() {
    cd "$loc/dist"
    zip -r9 "$1" "$name.app"
    cd "$loc"
}

do_create_dmg() {
    local dmgStaging="$loc/dist/dmg_staging"
    rm -rf "$dmgStaging"
    mkdir -p "$dmgStaging"
    cp -R "$loc/dist/$name.app" "$dmgStaging/"
    create-dmg \
        --volname "$name" \
        --volicon "$loc/res/main.icns" \
        --background "$loc/res/dmg/bg.png" \
        --window-pos 200 120 \
        --window-size 640 520 \
        --icon-size 128 \
        --icon "$name.app" 192 350 \
        --app-drop-link 448 350 \
        "$loc/dist/$shortName.dmg" \
        "$dmgStaging"
    rm -rf "$dmgStaging"
}

do_sign_dmg() {
    codesign --force --sign "$ICHAI_SIGNING_IDENTITY" --timestamp "$loc/dist/$shortName.dmg"
}

# notarytool exits 0 even when a submission is rejected; inspect the final
# status line so we fail before trying to staple a ticket that doesn't exist.
do_notarize() {
    local submissionLog finalStatus
    if [ -n "${ICHAI_NOTARY_PROFILE:-}" ]; then
        submissionLog="$(xcrun notarytool submit "$1" --keychain-profile "$ICHAI_NOTARY_PROFILE" --wait 2>&1)"
    else
        submissionLog="$(xcrun notarytool submit "$1" \
            --apple-id "$ICHAI_APPLE_ID" \
            --team-id "$ICHAI_TEAM_ID" \
            --password "$ICHAI_APP_PASSWORD" \
            --wait 2>&1)"
    fi
    echo "$submissionLog"
    finalStatus="$(echo "$submissionLog" | awk '/status:/ {print $2}' | tail -n 1)"
    if [ "$finalStatus" != "Accepted" ]; then
        echo "notarization did not succeed (status: ${finalStatus:-unknown})" >&2
        return 1
    fi
}

do_staple_app() { xcrun stapler staple "$loc/dist/$name.app"; }
do_staple_dmg() { xcrun stapler staple "$loc/dist/$shortName.dmg"; }

do_verify() {
    codesign --verify --deep --strict --verbose=2 "$loc/dist/$name.app"
    if [ "$can_notarize" = true ]; then
        xcrun stapler validate "$loc/dist/$name.app"
    fi
    if [ "$mode" = "release" ]; then
        spctl -a -vvv "$loc/dist/$shortName.dmg"
        if [ "$can_notarize" = true ]; then
            xcrun stapler validate "$loc/dist/$shortName.dmg"
        fi
    fi
}

do_upload() { share "$1"; }

# ── Clean ────────────────────────────────────────────────────────────

if [ "$mode" = "clean" ]; then
    swift package clean
    do_clean_app_cache
    echo -e "  ${greenColor}${bold}Clean complete.${noColor}"
    exit 0
fi

# ── Assemble pipeline ────────────────────────────────────────────────

do_init_log
do_clean_dist

if [ "$mode" = "test" ]; then
    add "Running app tests..."        "app tests failed"                          do_run_app_tests
    run_pipeline
    echo ""
    echo -e "  ${greenColor}${bold}Tests passed!${noColor}"
    exit 0
fi

add "Resolving dependencies..."      "failed to resolve dependencies"            do_resolve_deps
add "Building chat renderer (web)..." "failed to build chat renderer"            do_build_web
add "Compiling Swift (app)..." "failed to compile $shortName"             do_build_swift
add "Creating APP bundle..."         "failed to create app bundle"               do_create_bundle

# Tests gate signing for release builds.
if [ "$mode" != "dev" ]; then
    add "Running app tests..."            "app tests failed"                       do_run_app_tests
fi

add "Code-signing APP bundle..."     "failed to code-sign app bundle"            do_codesign

if [ "$mode" = "release" ]; then
    add "Creating distribution ZIP..." "failed to pack $shortName.zip"            do_create_zip "$shortName.zip"
    add "Creating distribution DMG..." "failed to create dmg"                     do_create_dmg
    if [ "$can_sign" = true ]; then
        add "Signing distribution DMG..." "failed to sign dmg"                    do_sign_dmg
    fi
    if [ "$can_notarize" = true ]; then
        add "Notarizing release build..." "failed to notarize release build"      do_notarize "$loc/dist/$shortName.dmg"
        add "Stapling APP bundle..."      "failed to staple app bundle"           do_staple_app
        add "Stapling release DMG..."     "failed to staple release DMG"          do_staple_dmg
    fi
    if [ "$can_sign" = true ]; then
        add "Verifying signatures..."     "failed to verify signatures"           do_verify
    fi
elif [ "$mode" = "dev-release" ]; then
    add "Creating dev ZIP..."          "failed to pack $shortName-dev.zip"        do_create_zip "$shortName-dev.zip"
    if [ "$can_notarize" = true ]; then
        add "Notarizing dev build..."     "failed to notarize dev build"          do_notarize "$loc/dist/$shortName-dev.zip"
        add "Stapling APP bundle..."      "failed to staple app bundle"           do_staple_app
    fi
    if [ "$can_sign" = true ]; then
        add "Verifying signatures..."     "failed to verify signatures"           do_verify
    fi
    add "Uploading dev build..."       "failed to upload dev build"              do_upload "$loc/dist/$shortName-dev.zip"
fi

run_pipeline

# ── Post-build ───────────────────────────────────────────────────────
echo ""
echo -e "  ${greenColor}${bold}Build complete!${noColor}"

case "$mode" in
    dev)
        echo -e "  ${dimColor}mode: development${noColor}"
        echo -e "  ${dimColor}signing: ad-hoc${noColor}"
        echo -e "  ${dimColor}artifacts: dist/$name.app${noColor}"
        echo -e "  ${dimColor}launching...${noColor}"
        "$loc/dist/$name.app/Contents/MacOS/$name"
        ;;
    dev-release)
        echo -e "  ${dimColor}mode: development release${noColor}"
        echo -e "  ${dimColor}signing: $(if [ "$can_sign" = true ]; then echo "Developer ID"; else echo "ad-hoc"; fi)${noColor}"
        echo -e "  ${dimColor}notarized: $(if [ "$can_notarize" = true ]; then echo "yes"; else echo "no"; fi)${noColor}"
        echo -e "  ${dimColor}artifacts: dist/$name.app  dist/$shortName-dev.zip${noColor}"
        ;;
    release)
        echo -e "  ${dimColor}mode: release${noColor}"
        echo -e "  ${dimColor}signing: $(if [ "$can_sign" = true ]; then echo "Developer ID"; else echo "ad-hoc"; fi)${noColor}"
        echo -e "  ${dimColor}notarized: $(if [ "$can_notarize" = true ]; then echo "yes"; else echo "no"; fi)${noColor}"
        echo -e "  ${dimColor}artifacts: dist/$name.app  dist/$shortName.zip  dist/$shortName.dmg${noColor}"
        ;;
esac
