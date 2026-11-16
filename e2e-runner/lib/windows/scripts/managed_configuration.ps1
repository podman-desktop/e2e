write-host "Setting up managed configuration files for Podman Desktop (or build) on Windows..."

$ManagedConfigDir = "$env:PROGRAMDATA\Podman Desktop"

if ($env:PRODUCT_TESTS -eq "true" -or $env:PRODUCT_TESTS -eq "1") {
    $ManagedConfigDir = "$env:PROGRAMDATA\Red Hat\Podman Desktop"
}

write-host "Working with '$ManagedConfigDir' managed directory"

# The managed-configuration resources live inside the podman-desktop repository.
# A repo is considered valid only when it contains this relative file.
$PdResourceSubDir = "tests\playwright\resources\managed-configuration"
$PdResourceMarker = "$PdResourceSubDir\default-settings.json"

# Locate the podman-desktop repository in a nearby location.
#
# The scripts are shipped inside the deliverest base image and executed by the
# runner from whatever its current directory happens to be, so the repo is not
# guaranteed to sit right next to the invocation directory. We probe a set of
# candidate locations, preferring hints provided by the deliverest base image
# (TARGET_FOLDER delivered under the user profile) and falling back to a
# bounded search.
function Find-PodmanDesktopRepo {
    $candidates = @()

    # Canonical home. The search must never leave the user's home folder, so
    # every resolved path and search root is validated against this prefix.
    $homeReal = $env:USERPROFILE
    try { $homeReal = (Resolve-Path $env:USERPROFILE -ErrorAction Stop).Path } catch {}

    # True only when $Path (already resolved) is inside the home folder.
    function Test-WithinHome([string]$Path) {
        if (-not $Path) { return $false }
        return ($Path -eq $homeReal -or $Path.StartsWith("$homeReal\", [System.StringComparison]::OrdinalIgnoreCase))
    }

    # Authoritative location first: the deliverest base image copies the runner
    # assets into TARGET_FOLDER (typically under the target user's profile) and
    # the runner clones podman-desktop beside them. Target machines may carry
    # other unrelated podman-desktop checkouts, so the delivered one must win.
    if ($env:TARGET_FOLDER) {
        $candidates += "$env:TARGET_FOLDER\podman-desktop"
        $candidates += "$env:USERPROFILE\$env:TARGET_FOLDER\podman-desktop"
    }
    # The runner may export its working directory.
    if ($env:WORKING_DIR) {
        $candidates += "$env:WORKING_DIR\podman-desktop"
    }

    # Script-location anchor: these scripts live in <workingDir>\scripts and the
    # repo is cloned beside them, so it sits one level up from this script
    # regardless of the current directory. Reliable when TARGET_FOLDER is unset.
    if ($PSScriptRoot) {
        $candidates += (Join-Path $PSScriptRoot "..\podman-desktop")
    }

    # Current directory may already be the repo (e.g. runner cd'd into it).
    $candidates += "."
    # Legacy assumption: repo cloned next to the invocation directory.
    $candidates += "podman-desktop"
    # Walk up a couple of levels in case we are nested (e.g. inside an ext repo).
    $candidates += "..\podman-desktop"
    $candidates += "..\..\podman-desktop"
    $candidates += "$env:USERPROFILE\podman-desktop"

    foreach ($candidate in $candidates) {
        if (Test-Path (Join-Path $candidate $PdResourceMarker)) {
            $resolved = (Resolve-Path $candidate).Path
            if (-not (Test-WithinHome $resolved)) {
                write-host "  candidate '$candidate' -> '$resolved' is outside HOME ('$homeReal'), skipping"
                continue
            }
            write-host "Resolved podman-desktop repository via candidate '$candidate' -> '$resolved'"
            return $resolved
        }
        write-host "  candidate not matched: '$candidate'"
    }

    # Last resort: bounded search in nearby, likely locations for the marker,
    # starting from the deliverest target folder before widening the search.
    # Search roots are confined to the home folder so the scan never escapes it.
    $searchRoots = @()
    if ($env:TARGET_FOLDER) {
        $searchRoots += "$env:USERPROFILE\$env:TARGET_FOLDER"
        $searchRoots += "$env:TARGET_FOLDER"
    }
    $searchRoots += @(".", "..", "$env:USERPROFILE")
    foreach ($root in $searchRoots) {
        if (-not $root -or -not (Test-Path $root)) { continue }
        $rootReal = (Resolve-Path $root).Path
        if (-not (Test-WithinHome $rootReal)) {
            write-host "  skipping search root '$root' -> '$rootReal' (outside HOME)"
            continue
        }
        # Marker sits a few levels deep; depth 6 lets the repo root be up to a
        # couple of levels below the search root (parity with the unix script).
        write-host "  searching under '$rootReal' (depth 6) for '$PdResourceMarker'..."
        $found = Get-ChildItem -Path $rootReal -Recurse -Depth 6 -Filter "default-settings.json" `
            -File -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -like "*\$PdResourceMarker" } |
            Select-Object -First 1
        if ($found) {
            # <repo>\tests\playwright\resources\managed-configuration\default-settings.json
            $resolved = (Resolve-Path (Join-Path $found.Directory.FullName "..\..\..\..")).Path
            if (-not (Test-WithinHome $resolved)) {
                write-host "  search hit '$resolved' is outside HOME, skipping"
                continue
            }
            write-host "Resolved podman-desktop repository via bounded search under '$rootReal' (marker '$($found.FullName)') -> '$resolved'"
            return $resolved
        }
    }

    return $null
}

# Preserve the runner's working directory. Execute-Scripts runs this script with
# the call operator (& $scriptPath) in the SAME runspace, so any location change
# here would leak back into runner.ps1 and break the subsequent `pnpm install`,
# which depends on the current directory being the repo checkout. We never change
# the location below, but restore it in a finally as a hard guarantee.
$originalLocation = Get-Location
write-host "Current directory: $($originalLocation.Path)"
write-host "Searching for podman-desktop repository (TARGET_FOLDER='$($env:TARGET_FOLDER)', WORKING_DIR='$($env:WORKING_DIR)', USERPROFILE='$env:USERPROFILE')..."
try {
    $PdRepoDir = Find-PodmanDesktopRepo

    if ($PdRepoDir) {
        write-host "Using podman-desktop repository at: $PdRepoDir"
        write-host "Setting up managed configuration for Windows"
        New-Item -ItemType Directory -Force -Path $ManagedConfigDir | Out-Null

        $testDefault = Join-Path $PdRepoDir "$PdResourceSubDir\default-settings.json"
        $testLocked = Join-Path $PdRepoDir "$PdResourceSubDir\locked.json"
        write-host "Source default-settings: $testDefault"
        write-host "Source locked: $testLocked"

        if (Test-Path $testDefault) {
            Copy-Item -Path $testDefault -Destination "$ManagedConfigDir\default-settings.json" -Force
            write-host "Default settings:"
            Get-Content "$ManagedConfigDir\default-settings.json"
        } else {
            # Do NOT call `exit` here: Execute-Scripts runs this script with the call
            # operator (& $scriptPath) in the SAME runspace, so `exit` would terminate
            # runner.ps1 itself. Report the failure and return cleanly instead.
            Write-Error "$testDefault does not exist..."
            return
        }

        if (Test-Path $testLocked) {
            Copy-Item -Path $testLocked -Destination "$ManagedConfigDir\locked.json" -Force
            write-host "Locked settings:"
            Get-Content "$ManagedConfigDir\locked.json"
        } else {
            Write-Error "$testLocked does not exist..."
            return
        }
    } else {
        Write-Error "podman-desktop repository not found in any nearby location, could not set managed config..."
        write-host "Searched relative to current directory ($($originalLocation.Path)), TARGET_FOLDER ('$($env:TARGET_FOLDER)') and USERPROFILE ('$env:USERPROFILE')."
        return
    }
} finally {
    # Restore the runner's working directory for the steps that follow (pnpm install).
    Set-Location $originalLocation
}
