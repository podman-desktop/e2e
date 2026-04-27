# Addresses this unstability from Windows 10 Azure runners https://github.com/podman-desktop/podman-desktop/issues/14825

Write-Host "---Checking WSL availability---"
$wslStatus = wsl --status 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Host "WSL is not enabled or not properly installed, skipping DNS fix"
    exit 0
}

Write-Host "---Setting up .wslconfig---"
# Just in case the podman machine is re-created during tests or there is no machine to begin with
# With dnsProxy=false, WSL will mirror the Windows DNS servers (8.8.8.8) to Linux
$wslConfigPath = "$env:USERPROFILE\.wslconfig"
$wslConfigContent = @"
[wsl2]
dnsProxy=false
"@
Set-Content -Path $wslConfigPath -Value $wslConfigContent -Force
Write-Host ".wslconfig created at: $wslConfigPath"
Get-Content $wslConfigPath

Write-Host "---Verifying WSL distributions---"
$distros = wsl --list --quiet 2>$null
if (-not $distros) {
    Write-Host "No WSL distributions installed, machine should be created during tests with .wslconfig settings"
    exit 0
}else{
    Write-Host "WSL is available with distributions: $($distros -join ', ')"
}

Write-Host "---Making sure podman is the current WSL distribution---"
# Get list of installed WSL distributions and filter for podman ones
$podmanDistros = $distros | Where-Object { $_ -match "podman" }
if ($podmanDistros) {
    $podmanDistrosList = @($podmanDistros)
    Write-Host "Found podman distributions: $($podmanDistrosList -join ', ')"
    
    # Check if podman-machine-default exists, otherwise use the first podman distro
    if ($podmanDistrosList -contains "podman-machine-default") {
        $targetDistro = "podman-machine-default"
    } else {
        $targetDistro = $podmanDistrosList[0]
    }
    
    Write-Host "Setting default WSL distribution to: $targetDistro"
    wsl --set-default $targetDistro
    if ($LASTEXITCODE -eq 0) {
        Write-Host "Successfully set $targetDistro as default WSL distribution"
    } else {
        Write-Host "Warning: Failed to set $targetDistro as default WSL distribution"
    }
} else {
    Write-Host "No podman distributions found, skipping default distribution setup"
}

Write-Host "---Verifying if DNS resolution is working or not---"
$result = wsl -e curl -s -o /dev/null -w '%{http_code}' --connect-timeout 5 https://ghcr.io 2>$null
if ($result -match "^[23]\d{2}$") { # 200-299 = Success; 300-399 = Redirect
    Write-Host "DNS resolution is working (HTTP $result), no fix needed"
    exit 0
}
Write-Host "DNS resolution failed (HTTP $result), applying fix"

Write-Host "---Current configuration status---"
wsl -e sudo cat /etc/wsl.conf

Write-Host "---Changing default DNS behavior---"
# appends a [network] entry if it doesn't exist already
wsl -e sudo bash -c "grep -q '\[network\]' /etc/wsl.conf 2>/dev/null || printf '\n[network]\n' >> /etc/wsl.conf; grep -q 'generateResolvConf' /etc/wsl.conf || echo 'generateResolvConf = false' >> /etc/wsl.conf" 
wsl -e sudo cat /etc/wsl.conf 

Write-Host "---Specifying a more reliable DNS server---"
wsl -e sudo rm -f /etc/resolv.conf 
wsl -e sudo bash -c "echo 'nameserver 8.8.8.8' > /etc/resolv.conf" 
wsl -e sudo cat /etc/resolv.conf 

Write-Host "---Setting Windows Host DNS to 8.8.8.8---"
# Set DNS on all active network adapters so WSL can mirror it
$adapters = Get-NetAdapter | Where-Object { $_.Status -eq "Up" }

Write-Host "Current DNS configuration before changes:"
Get-DnsClientServerAddress -AddressFamily IPv4 | Where-Object { $_.ServerAddresses } | Format-Table -AutoSize

foreach ($adapter in $adapters) {
    Write-Host "Setting DNS for adapter: $($adapter.Name)"
    Set-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex -ServerAddresses "8.8.8.8","8.8.4.4"
}

Write-Host "DNS configuration after changes:"
Get-DnsClientServerAddress -AddressFamily IPv4 | Where-Object { $_.ServerAddresses } | Format-Table -AutoSize

Write-Host "---Restarting WSL to apply changes---"
wsl --shutdown
Start-Sleep -Seconds 2

Write-Host "---Verifying if DNS resolution is working after the applied fix---"
$result = wsl -e curl -s -o /dev/null -w '%{http_code}' --connect-timeout 5 https://ghcr.io 2>$null
if ($result -match "^[23]\d{2}$") { # 200-299 = Success; 300-399 = Redirect
    Write-Host "DNS resolution is working (HTTP $result), the fix worked"
    exit 0
}
Write-Host "DNS resolution failed (HTTP $result), the fix did not work"
