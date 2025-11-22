
param(
    [Parameter(Mandatory,HelpMessage='folder on target host where assets are copied')]
    $targetFolder,
    [Parameter(Mandatory,HelpMessage='Results folder')]
    $resultsFolder="results"
)

# Execution beginning
Write-Host "Podman desktop E2E runner script is being run..."
$actualUser=whoami
Write-Host "Whoami: $actualUser"

write-host "Switching to a target folder: " $targetFolder
cd $targetFolder
write-host "Create a $resultsFolder in targetFolder"
mkdir -p $resultsFolder
$workingDir=Get-Location
write-host "Working location: " $workingDir
$targetLocation="$workingDir\$resultsFolder"

. $workingDir/common.ps1

hello
