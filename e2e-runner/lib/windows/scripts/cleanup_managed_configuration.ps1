write-host "Cleaning up managed configuration files for Podman Desktop on Windows..."

$ManagedConfigDir = "$env:PROGRAMDATA\Podman Desktop"

if ($env:PRODUCT_TESTS -eq "true" -or $env:PRODUCT_TESTS -eq "1") {
    $ManagedConfigDir = "$env:PROGRAMDATA\Red Hat\Podman Desktop"
}

write-host "Working with '$ManagedConfigDir' managed directory"

$ManagedFiles = @("default-settings.json", "locked.json")

if (Test-Path $ManagedConfigDir) {
    foreach ($file in $ManagedFiles) {
        $filePath = Join-Path $ManagedConfigDir $file
        if (Test-Path $filePath) {
            write-host "Removing $filePath"
            Remove-Item -Path $filePath -Force
        }
    }
    if (-not (Get-ChildItem -Path $ManagedConfigDir -Force -ErrorAction SilentlyContinue)) {
        write-host "Removing empty directory $ManagedConfigDir"
        Remove-Item -Path $ManagedConfigDir -Force
    }
} else {
    write-host "Managed configuration directory does not exist, skipping"
}

$RegistriesConf = "$env:USERPROFILE\.config\containers\registries.conf"
if (Test-Path $RegistriesConf) {
    write-host "Removing generated registries.conf at $RegistriesConf"
    Remove-Item -Path $RegistriesConf -Force
} else {
    write-host "No registries.conf found, skipping"
}

write-host "Managed configuration cleanup complete."
