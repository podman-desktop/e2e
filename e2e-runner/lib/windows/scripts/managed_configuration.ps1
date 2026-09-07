write-host "Setting up managed configuration files for Podman Desktop (or build) on Windows..."

$ManagedConfigDir = "$env:PROGRAMDATA\Podman Desktop"

if ($env:PRODUCT_TESTS -eq "true" -or $env:PRODUCT_TESTS -eq "1") {
    $ManagedConfigDir = "$env:PROGRAMDATA\Red Hat\Podman Desktop"
}

write-host "Working with '$ManagedConfigDir' managed directory"

if (Test-Path "podman-desktop") {
    write-host "checkout to podman-desktop repo..."
    Set-Location "podman-desktop"
    write-host "Setting up managed configuration for Windows"
    New-Item -ItemType Directory -Force -Path $ManagedConfigDir | Out-Null

    $testDefault = "tests\playwright\resources\managed-configuration\default-settings.json"
    $testLocked = "tests\playwright\resources\managed-configuration\locked.json"

    if (Test-Path $testDefault) {
        Copy-Item -Path $testDefault -Destination "$ManagedConfigDir\default-settings.json" -Force
        write-host "Default settings:"
        Get-Content "$ManagedConfigDir\default-settings.json"
    } else {
        write-host "$testDefault does not exist..."
        exit 1
    }

    if (Test-Path $testLocked) {
        Copy-Item -Path $testLocked -Destination "$ManagedConfigDir\locked.json" -Force
        write-host "Locked settings:"
        Get-Content "$ManagedConfigDir\locked.json"
    } else {
        write-host "$testLocked does not exist..."
        exit 1
    }
} else {
    write-host "podman-desktop repository not found, could not set managed config..."
    exit 1
}
