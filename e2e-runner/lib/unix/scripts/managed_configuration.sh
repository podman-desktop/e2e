#!/bin/bash
set -e

echo "Setting up managed configuration files for Podman Desktop (or build) on Unix..."

MANAGED_CONFIG_DIR="/Library/Application Support/io.podman_desktop.PodmanDesktop"
MANAGED_FILES=("default-settings.json" "locked.json")

if [[ "$PRODUCT_TESTS" == "true" || "$PRODUCT_TESTS" == "1" ]]; then
    if [ "$(uname)" == "Linux" ]; then
        MANAGED_CONFIG_DIR="/usr/share/rh-podman-desktop"
    else
        MANAGED_CONFIG_DIR="/Library/Application Support/com.redhat.PodmanDesktop"
    fi
else
    if [ "$(uname)" == "Linux" ]; then
        MANAGED_CONFIG_DIR="/usr/share/podman-desktop"
    fi
fi

echo "Working with '$MANAGED_CONFIG_DIR' managed directory"

# The managed-configuration resources live inside the podman-desktop repository.
# A repo is considered valid only when it contains this relative file.
PD_RESOURCE_SUBDIR="tests/playwright/resources/managed-configuration"
PD_RESOURCE_MARKER="$PD_RESOURCE_SUBDIR/default-settings.json"

# Locate the podman-desktop repository in a nearby location.
#
# The scripts are shipped inside the deliverest base image and executed by the
# runner from whatever its current directory happens to be, so the repo is not
# guaranteed to sit right next to the invocation directory. We probe a set of
# candidate locations, preferring hints provided by the deliverest base image
# (TARGET_FOLDER delivered under HOME) and falling back to a bounded search.
find_podman_desktop_repo() {
    local candidates=()

    # Canonical home. The search must never leave the user's home folder, so
    # every resolved path and search root is validated against this prefix.
    local home_real
    home_real=$( cd "$HOME" 2>/dev/null && pwd -P ) || home_real="$HOME"

    # Authoritative location first: the deliverest base image copies the runner
    # assets into TARGET_FOLDER (typically under the target user's HOME) and the
    # runner clones podman-desktop beside them. Target machines may carry other
    # unrelated podman-desktop checkouts, so the delivered one must win.
    if [ -n "$TARGET_FOLDER" ]; then
        candidates+=("$TARGET_FOLDER/podman-desktop")
        candidates+=("$HOME/$TARGET_FOLDER/podman-desktop")
    fi
    # The runner may export its working directory.
    if [ -n "$WORKING_DIR" ]; then
        candidates+=("$WORKING_DIR/podman-desktop")
    fi

    # Script-location anchor: these scripts live in <workingDir>/unix/scripts and
    # the repo is cloned beside them, so it sits two levels up from this script
    # regardless of the current directory. Reliable when TARGET_FOLDER is unset.
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    candidates+=("$script_dir/../../podman-desktop")

    # Current directory may already be the repo (e.g. runner cd'd into it).
    candidates+=(".")
    # Legacy assumption: repo cloned next to the invocation directory.
    candidates+=("./podman-desktop")
    # Walk up a couple of levels in case we are nested (e.g. inside an ext repo).
    candidates+=("../podman-desktop" "../../podman-desktop")
    candidates+=("$HOME/podman-desktop")

    # True only when $1 (an existing canonical path) is inside the home folder.
    within_home() {
        case "$1" in
            "$home_real"|"$home_real"/*) return 0 ;;
            *) return 1 ;;
        esac
    }

    # Logs go to stderr so they do not pollute the resolved path on stdout.
    local candidate resolved
    for candidate in "${candidates[@]}"; do
        if [ -f "$candidate/$PD_RESOURCE_MARKER" ]; then
            resolved=$( cd "$candidate" && pwd -P )
            if ! within_home "$resolved"; then
                echo "  candidate '$candidate' -> '$resolved' is outside HOME ('$home_real'), skipping" >&2
                continue
            fi
            echo "Resolved podman-desktop repository via candidate '$candidate' -> '$resolved'" >&2
            echo "$resolved"
            return 0
        fi
        echo "  candidate not matched: '$candidate'" >&2
    done

    # Last resort: bounded search in nearby, likely locations for the marker,
    # starting from the deliverest target folder before widening the search.
    # Search roots are confined to the home folder so the scan never escapes it.
    local search_root root_real found
    for search_root in "$HOME/$TARGET_FOLDER" "$TARGET_FOLDER" "." ".." "$HOME"; do
        [ -n "$search_root" ] || continue
        [ -d "$search_root" ] || continue
        root_real=$( cd "$search_root" 2>/dev/null && pwd -P ) || continue
        if ! within_home "$root_real"; then
            echo "  skipping search root '$search_root' -> '$root_real' (outside HOME)" >&2
            continue
        fi
        # Marker is 5 components deep; allow the repo root up to 1 level below search root.
        echo "  searching under '$root_real' (maxdepth 6) for '$PD_RESOURCE_MARKER'..." >&2
        found=$(find "$root_real" -maxdepth 6 \
            \( -name node_modules -o -name .git \) -prune -o \
            -type f -path "*/$PD_RESOURCE_MARKER" -print 2>/dev/null | head -1)
        if [ -n "$found" ]; then
            resolved=$( cd "$(dirname "$found")/../../../.." && pwd -P )
            if ! within_home "$resolved"; then
                echo "  search hit '$resolved' is outside HOME, skipping" >&2
                continue
            fi
            echo "Resolved podman-desktop repository via bounded search under '$root_real' (marker '$found') -> '$resolved'" >&2
            echo "$resolved"
            return 0
        fi
    done

    return 1
}

echo "Current directory: $(pwd)"
echo "Searching for podman-desktop repository (TARGET_FOLDER='${TARGET_FOLDER:-unset}', WORKING_DIR='${WORKING_DIR:-unset}', HOME='$HOME')..."
if PD_REPO_DIR=$(find_podman_desktop_repo); then
    echo "Using podman-desktop repository at: $PD_REPO_DIR"
    echo "Setting up managed configuration for Linux and Mac OS"
    sudo mkdir -p "$MANAGED_CONFIG_DIR"
    test_default="$PD_REPO_DIR/$PD_RESOURCE_SUBDIR/default-settings.json"
    test_locked="$PD_REPO_DIR/$PD_RESOURCE_SUBDIR/locked.json"
    echo "Source default-settings: $test_default"
    echo "Source locked: $test_locked"
    if [ -f "$test_default" ]; then
        sudo cp "$test_default" "$MANAGED_CONFIG_DIR/default-settings.json"
        echo "Default settings:" && cat "$MANAGED_CONFIG_DIR/default-settings.json"
    else
        echo "$test_default does not exist..."
        exit 1
    fi
    if [ -f "$test_locked" ]; then
        sudo cp "$test_locked" "$MANAGED_CONFIG_DIR/locked.json"
        echo "Locked settings:" && cat "$MANAGED_CONFIG_DIR/locked.json"
    else
        echo "$test_locked does not exist..."
        exit 1
    fi
else
    echo "podman-desktop repository not found in any nearby location, could not set managed config..."
    echo "Searched relative to current directory ($(pwd)), TARGET_FOLDER ('${TARGET_FOLDER:-unset}') and HOME ('$HOME')."
    exit 1
fi
