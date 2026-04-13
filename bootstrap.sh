#!/usr/bin/env bash
# Symposium Bootstrap — installs the .symposium file type handler on macOS
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/Heretyc/symposium/main/bootstrap.sh | bash
#
# What this does:
#   Creates ~/.symposium/SymposiumInstaller.app via osacompile, registers it
#   as the macOS handler for .symposium archives, and registers it with
#   Launch Services so double-clicking a .symposium file immediately invokes
#   the handler without a logout/login cycle.
#
# What this does NOT do:
#   It does not install Symposium itself. Installation and updates happen
#   when you double-click a .symposium archive.
#
# Requirements:
#   - macOS 12 (Monterey) or later
#   - No admin/sudo required
#
set -euo pipefail

# ── Constants ────────────────────────────────────────────────────────────────

SYMPOSIUM_DIR="$HOME/.symposium"
APP_NAME="SymposiumInstaller"
# ~/Applications/ is in Launch Services' automatic scan path; ~/.symposium/ is not.
APP_BUNDLE="$HOME/Applications/$APP_NAME.app"
CONTENTS="$APP_BUNDLE/Contents"
PLIST="$CONTENTS/Info.plist"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

BOLD='\033[1m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
DIM='\033[2m'
NC='\033[0m'

# ── Preflight ─────────────────────────────────────────────────────────────────

check_macos_version() {
    local version
    version="$(sw_vers -productVersion)"
    local major
    major="$(echo "$version" | cut -d. -f1)"
    if [[ "$major" -lt 12 ]]; then
        echo -e "${RED}Error:${NC} macOS 12 (Monterey) or later is required. You have $version."
        exit 1
    fi
}

check_dependencies() {
    local missing=()
    for cmd in osacompile unzip curl; do
        if ! command -v "$cmd" &>/dev/null; then
            missing+=("$cmd")
        fi
    done
    if [[ "${#missing[@]}" -gt 0 ]]; then
        echo -e "${RED}Error:${NC} Missing required commands: ${missing[*]}"
        exit 1
    fi
    if [[ ! -x "$LSREGISTER" ]]; then
        echo -e "${RED}Error:${NC} lsregister not found at expected path."
        echo "  Expected: $LSREGISTER"
        exit 1
    fi
}

# ── Step 1: Directory ─────────────────────────────────────────────────────────

create_symposium_dir() {
    mkdir -p "$SYMPOSIUM_DIR"
    mkdir -p "$HOME/Applications"
}

# ── Step 2: Build the AppleScript handler app ─────────────────────────────────
#
# The handler app receives .symposium archives via Apple Events (on open theFiles).
# It extracts the archive to a temp directory and opens Terminal to run install.sh
# so the user sees real-time cargo build progress.
#
# On first use, macOS will prompt:
#   "SymposiumInstaller wants to control Terminal. Allow?"
# The user clicks Allow once; subsequent invocations skip the prompt.
# If the user denies it, the handler falls back to a background install
# with a notification.
#
compile_handler_app() {
    # Clean up any previous install and any stale temp artifacts from failed runs.
    rm -rf "$APP_BUNDLE"
    rm -f /tmp/symposium_handler_* 2>/dev/null || true
    rm -rf /tmp/symposium_compile_* 2>/dev/null || true

    local script_tmp tmp_compile_dir tmp_bundle
    script_tmp="$(mktemp /tmp/symposium_handler_XXXXXX)"

    # osacompile requires the output path to end in .app to produce a bundle.
    # Without it, osacompile writes a flat compiled .scpt file and PlistBuddy
    # fails because there is no Contents/ directory to patch.
    # Compile into a temp dir in /tmp (avoids -1750 on non-standard paths),
    # then move the finished bundle into place.
    tmp_compile_dir="$(mktemp -d /tmp/symposium_compile_XXXXXX)"
    tmp_bundle="$tmp_compile_dir/SymposiumInstaller.app"

    # shellcheck disable=SC2016
    cat > "$script_tmp" << 'OSASCRIPT'
on open theFiles
    repeat with aFile in theFiles
        set filePath to POSIX path of aFile
        set extractBase to "/tmp/symposium_install_" & (do shell script "date +%s%N 2>/dev/null || date +%s")
        set installScript to extractBase & "/install.sh"

        try
            -- Extract the .symposium archive (it is a ZIP with a renamed extension).
            do shell script "unzip -q " & quoted form of filePath & " -d " & quoted form of extractBase

            if not (do shell script "test -f " & quoted form of installScript & " && echo yes" as boolean) then
                display dialog "Invalid .symposium archive: install.sh not found inside the package." ¬
                    buttons {"OK"} default button "OK" with icon stop
                do shell script "rm -rf " & quoted form of extractBase
                return
            end if

            -- Open Terminal so the user sees real-time build output.
            -- The Automation permission dialog fires once; click Allow.
            try
                tell application "Terminal"
                    activate
                    do script "echo ''; echo '━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━'; echo '  Symposium Installer'; echo '━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━'; echo ''; bash " & quoted form of installScript & " " & quoted form of extractBase & "; RESULT=$?; echo ''; if [ $RESULT -eq 0 ]; then echo '✓ Symposium installed successfully. Close this window.'; else echo '✗ Installation failed (exit ' & RESULT & '). See output above.'; fi"
                end tell
            on error
                -- Automation permission denied or Terminal unavailable: run in background.
                do shell script "bash " & quoted form of installScript & " " & quoted form of extractBase & " > /tmp/symposium_install.log 2>&1 &"
                display notification "Installing Symposium in the background. Check /tmp/symposium_install.log for progress." ¬
                    with title "Symposium Installer"
            end try

        on error errMsg number errNum
            display dialog "Symposium installer encountered an error:" & return & return & errMsg ¬
                buttons {"OK"} default button "OK" with icon stop
            do shell script "rm -rf " & quoted form of extractBase & " 2>/dev/null || true"
        end try
    end repeat
end open

-- Invoked when user double-clicks the .app itself (not a .symposium file).
on run
    display dialog "Symposium Installer is ready." & return & return & ¬
        "Double-click a .symposium archive to install or update Symposium." ¬
        buttons {"OK"} default button "OK" with icon note
end run
OSASCRIPT

    osacompile -l AppleScript -o "$tmp_bundle" "$script_tmp"
    rm -f "$script_tmp"
    mv "$tmp_bundle" "$APP_BUNDLE"
    rm -rf "$tmp_compile_dir"
}

# ── Step 3: Patch Info.plist ──────────────────────────────────────────────────
#
# osacompile writes a minimal Info.plist. We extend it with:
#   - A proper CFBundleIdentifier
#   - UTExportedTypeDeclarations  — declares the dev.symposium.package UTI
#   - CFBundleDocumentTypes       — claims Owner handler rank for .symposium
#
# Both sections are required: UTExportedTypeDeclarations makes macOS aware the
# UTI exists; CFBundleDocumentTypes claims this app handles files of that type.
#
patch_plist() {
    local pb="/usr/libexec/PlistBuddy"

    # Identifier
    "$pb" -c "Set :CFBundleIdentifier dev.symposium.installer" "$PLIST" 2>/dev/null \
        || "$pb" -c "Add :CFBundleIdentifier string dev.symposium.installer" "$PLIST"

    # Minimum OS version
    "$pb" -c "Set :LSMinimumSystemVersion 12.0" "$PLIST" 2>/dev/null \
        || "$pb" -c "Add :LSMinimumSystemVersion string 12.0" "$PLIST"

    # Suppress dock icon — this is a background file-handler, not a foreground app.
    "$pb" -c "Set :LSUIElement true" "$PLIST" 2>/dev/null \
        || "$pb" -c "Add :LSUIElement bool true" "$PLIST"

    # ── UTExportedTypeDeclarations ────────────────────────────────────────────
    "$pb" -c "Add :UTExportedTypeDeclarations array" "$PLIST" 2>/dev/null || true
    "$pb" -c "Add :UTExportedTypeDeclarations:0 dict" "$PLIST"
    "$pb" -c "Add :UTExportedTypeDeclarations:0:UTTypeIdentifier string dev.symposium.package" "$PLIST"
    "$pb" -c "Add :UTExportedTypeDeclarations:0:UTTypeDescription string Symposium Package" "$PLIST"
    "$pb" -c "Add :UTExportedTypeDeclarations:0:UTTypeConformsTo array" "$PLIST"
    "$pb" -c "Add :UTExportedTypeDeclarations:0:UTTypeConformsTo:0 string public.zip-archive" "$PLIST"
    "$pb" -c "Add :UTExportedTypeDeclarations:0:UTTypeTagSpecification dict" "$PLIST"
    "$pb" -c "Add :UTExportedTypeDeclarations:0:UTTypeTagSpecification:public.filename-extension array" "$PLIST"
    "$pb" -c "Add :UTExportedTypeDeclarations:0:UTTypeTagSpecification:public.filename-extension:0 string symposium" "$PLIST"

    # ── CFBundleDocumentTypes ─────────────────────────────────────────────────
    "$pb" -c "Add :CFBundleDocumentTypes array" "$PLIST" 2>/dev/null || true
    "$pb" -c "Add :CFBundleDocumentTypes:0 dict" "$PLIST"
    "$pb" -c "Add :CFBundleDocumentTypes:0:CFBundleTypeName string Symposium Package" "$PLIST"
    "$pb" -c "Add :CFBundleDocumentTypes:0:CFBundleTypeRole string Viewer" "$PLIST"
    "$pb" -c "Add :CFBundleDocumentTypes:0:LSHandlerRank string Owner" "$PLIST"
    "$pb" -c "Add :CFBundleDocumentTypes:0:CFBundleTypeExtensions array" "$PLIST"
    "$pb" -c "Add :CFBundleDocumentTypes:0:CFBundleTypeExtensions:0 string symposium" "$PLIST"
    "$pb" -c "Add :CFBundleDocumentTypes:0:LSItemContentTypes array" "$PLIST"
    "$pb" -c "Add :CFBundleDocumentTypes:0:LSItemContentTypes:0 string dev.symposium.package" "$PLIST"
}

# ── Step 4: Register with Launch Services ────────────────────────────────────
#
# -r           : recursive scan of the bundle
# domain flags : register in all three domains so the association applies
#                regardless of which user context opens the file
#
register_with_launch_services() {
    "$LSREGISTER" -r -domain local -domain system -domain user "$APP_BUNDLE"
}

# ── Step 5: Smoke-test the registration ──────────────────────────────────────
#
# Verify that lsregister actually associated .symposium with our app.
# Returns 0 if found, 1 if not (non-fatal — user can still proceed).
#
verify_registration() {
    local result
    result="$("$LSREGISTER" -dump 2>/dev/null | grep -c "symposium" || true)"
    [[ "$result" -gt 0 ]]
}

# ── Main ──────────────────────────────────────────────────────────────────────

main() {
    echo ""
    echo -e "${BOLD}Symposium Bootstrap${NC}"
    echo -e "${DIM}Installs the .symposium file type handler${NC}"
    echo ""

    echo -ne "  Checking prerequisites..."
    check_macos_version
    check_dependencies
    echo -e " ${GREEN}OK${NC}"

    echo -ne "  Creating ~/.symposium/..."
    create_symposium_dir
    echo -e " ${GREEN}OK${NC}"

    echo -ne "  Compiling handler app..."
    compile_handler_app
    echo -e " ${GREEN}OK${NC}"

    echo -ne "  Patching Info.plist..."
    patch_plist
    echo -e " ${GREEN}OK${NC}"

    echo -ne "  Registering with Launch Services..."
    register_with_launch_services
    echo -e " ${GREEN}OK${NC}"

    echo -ne "  Verifying registration..."
    if verify_registration; then
        echo -e " ${GREEN}OK${NC}"
    else
        echo -e " ${YELLOW}WARN${NC} (may need a Finder restart — try logging out and back in if .symposium files don't open)"
    fi

    echo ""
    echo -e "${GREEN}${BOLD}Bootstrap complete.${NC}"
    echo ""
    echo -e "  ${BOLD}Next step:${NC} Double-click a ${BOLD}.symposium${NC} archive to install or update Symposium."
    echo ""
    echo -e "  ${DIM}Handler location: $APP_BUNDLE${NC}"
    echo -e "  ${DIM}On first use, click Allow when macOS asks if SymposiumInstaller"
    echo -e "  can control Terminal. This appears once.${NC}"
    echo ""
}

main "$@"
