param(
    [Parameter(HelpMessage='url to download the exe for podman desktop, in case we want to test an specific build')]
    $pdUrl="",
    [Parameter(HelpMessage='path for the exe for podman desktop to be tested')]
    $pdPath="",
    [Parameter(Mandatory,HelpMessage='folder on target host where assets are copied')]
    $targetFolder,
    [Parameter(Mandatory,HelpMessage='Results folder')]
    $resultsFolder="results",
    [Parameter(HelpMessage = 'Podman Desktop Fork')]
    [string]$fork = "podman-desktop",
    [Parameter(HelpMessage = 'Podman Desktop Branch')]
    [string]$branch = "main",
    [Parameter(HelpMessage = 'Podman Desktop Repository name')]
    [string]$repo = "podman-desktop",
    [Parameter(HelpMessage = 'Extension repo')]
    [string]$extRepo = "",
    [Parameter(HelpMessage = 'Extension Fork')]
    [string]$extFork = "",
    [Parameter(HelpMessage = 'Extension Branch')]
    [string]$extBranch = "",
    [Parameter(HelpMessage = 'Npm Target to run')]
    [string]$npmTarget = "test:e2e",
    [Parameter(HelpMessage = 'Run Extension Tests - 0/false')]
    $extTests='0',
    [Parameter(HelpMessage = 'Podman Installation path - bin directory')]
    [string]$podmanPath = "",
    [Parameter(HelpMessage = 'Initialize podman machine, default is 0/false')]
    $initialize='0',
    [Parameter(HelpMessage = 'Start Podman machine, default is 0/false')]
    $start='0',
    [Parameter(HelpMessage = 'Podman machine rootful flag, default 0/false')]
    $rootful='0',
    [Parameter(HelpMessage = 'Podman machine user-mode-networking flag, default 0/false')]
    $userNetworking='0',
    [Parameter(HelpMessage = 'Environmental variables to be passed from the CI into a script, tests parameterization')]
    $envVars='',
    [Parameter(HelpMessage = 'Environmental variable to define custom podman Provider')]
    [string]$podmanProvider='',
    [Parameter(HelpMessage = 'Path to a secret file')]
    [string]$secretFile='',
    [Parameter(HelpMessage = 'Scripts file names available on the image to execute, under scripts folder, divided with comma')]
    $scriptPaths='',
    [Parameter(HelpMessage = 'Save traces in test artifacts, default is 1/true')]
    $saveTraces='1',
    [Parameter(HelpMessage = 'Run tests as admin')]
    $runAsAdmin = '0',
    [Parameter(HelpMessage = 'Podman download URL for installation')]
    [string]$podmanDownloadUrl = "",
    [Parameter(HelpMessage = 'Install WSL on Windows, default is 0/false')]
    $installWSL = '0'
)

# Program Versions
$nodejsLatestVersion = "v24.15.0"
$gitVersion = '2.42.0.2'
$pnpmVersion = '10'

$global:scriptEnvVars = @()
$global:envVarDefs = @()

# Source common functions
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. "$scriptDir\windows\common\common.ps1"

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

# Capture resources path location
$resourcesPath=$workingDir

# Location for arbitrary scripts
$scriptsPath = Join-Path $workingDir 'scripts'

# define targetLocationTmpScp for temporary script files and outputs
$targetLocationTmpScp="$targetLocation\scripts"
New-Item -ErrorAction Ignore -ItemType directory -Path $targetLocationTmpScp

# Specify the user profile directory
$userProfile = $env:USERPROFILE

# Output file for built podman desktop binary
$outputFile = "podman-location.log"

# Specify the shared tools directory
$toolsInstallDir = Join-Path $userProfile 'tools'
if (-not(Test-Path -Path $toolsInstallDir)) {
    write-host "Tools directory does not exists, creating..."
    mkdir -p $toolsInstallDir
}

# Installation of podman desktop
$podmanDesktopBinary=""

if ([string]::IsNullOrWhiteSpace($pdPath))
{
    if (-not [string]::IsNullOrWhiteSpace($pdUrl)) {
        # set binary path
        if ($pdUrl.Contains('setup')) {
            # TODO: parametrization, in cases where product is not podman-desktop
            Download-PD('pd-setup.exe')
            write-host "Installing Podman Desktop from setup.exe file..."
            # run the installer
            # TODO: add logic to install pd either under user or for the machine scope (PROGRAM FILES)
            Start-Process -Wait -FilePath "$workingDir\pd-setup.exe" -ArgumentList "/S" -PassThru
            # podman desktop should be under $env:LOCALAPPDATA\Programs\podman-desktop
            # newly, it can be on $env:LOCALAPPDATA\Programs\Podman Desktop\
            $localAppDataPrograms="$env:LOCALAPPDATA\Programs"
            Get-ChildItem -Path $localAppDataPrograms
            $pdLocalAppData="$localAppDataPrograms\podman-desktop"
            if (Test-Path -Path "$pdLocalAppData") {
                write-host "Podman Desktop installation path: $pdLocalAppData"
            } else {
                $pdLocalAppData="$localAppDataPrograms\Podman Desktop"
                if (Test-Path -Path "$pdLocalAppData") {
                    write-host "Podman Desktop new installation path path: $pdLocalAppData"
                } else {
                    write-host "Podman Desktop installation path is missing..."
                    exit 1
                }
            }
            $pdPath="$pdLocalAppData\Podman Desktop.exe"
            write-host "Podman Desktop is installed on expected path: $pdLocalAppData"
            if (Test-Path -Path $pdPath -PathType Leaf) {
                write-host "Podman Desktop installation present..."
                mv "$pdPath" "$pdLocalAppData\pd.exe"
                write-host
                $podmanDesktopBinary="$pdLocalAppData\pd.exe"
            } else {
                write-host "Podman Desktop binary is missing..."
                ls $pdLocalAppData
                exit 1
            }
        } else {
            Download-PD('pd.exe')
            write-host "Only a binary is available from url..."
            $podmanDesktopBinary="$workingDir\pd.exe"
        }
    }
} else {
    # set podman desktop binary path
    $podmanDesktopBinary=$pdPath
}

# load variables
Load-Variables

# load secrets
Load-Secrets

# Install VC Redistributable
write-host "Install VC_Redistributable"
if (-not (Test-Path -Path "$toolsInstallDir\vc_redist.x64.exe" -PathType Container)) {
    Invoke-WebRequest -Uri "https://aka.ms/vs/17/release/vc_redist.x64.exe" -OutFile "$toolsInstallDir\vc_redist.x64.exe"
    $vcredistInstaller = "$toolsInstallDir\vc_redist.x64.exe"

    if (Test-Path $vcredistInstaller) {
        Start-Process -FilePath $vcredistInstaller -ArgumentList "/install", "/passive", "/norestart" -Wait
    } else {
        Write-Host "Installer not found at $vcredistInstaller"
    }
}

# Install or put the tool on the path, path is regenerated 
# TODO: this is not ideal for bare metal machines, as it always add new entry into PATH
# for ephemeral machines this is ok.
# TODO: add check for node version as it might break the install/compile commands
if (-not (Command-Exists "node -v")) {
    # Download and install the latest version of Node.js
    write-host "Installing node"
    # $nodejsLatestVersion = (Invoke-RestMethod -Uri 'https://nodejs.org/dist/index.json' | Sort-Object -Property version -Descending)[0].version
    if (-not (Test-Path -Path "$toolsInstallDir\node-$nodejsLatestVersion-win-x64" -PathType Container)) {
        Invoke-WebRequest -Uri "https://nodejs.org/dist/$nodejsLatestVersion/node-$nodejsLatestVersion-win-x64.zip" -OutFile "$toolsInstallDir\nodejs.zip"
        Expand-Archive -Path "$toolsInstallDir\nodejs.zip" -DestinationPath $toolsInstallDir
    }
    # we need to set node for local access in actually running script
    $nodePath = "$toolsInstallDir\node-$nodejsLatestVersion-win-x64\"
    $env:Path += ";$nodePath"
    # Setting node to be available for the machine scope
    # requires admin access
    if (-not (Is-In-Path $podmanPath 'MACHINE' )) {
        $command="[Environment]::SetEnvironmentVariable('Path', (`$Env:Path + ';$nodePath'), 'MACHINE')"
        Start-Process powershell.exe -ArgumentList "-NoProfile", "-ExecutionPolicy Bypass", "-Command $command" -Verb RunAs -Wait
        write-host "$([Environment]::GetEnvironmentVariable('Path', 'MACHINE'))"
    }
}
# verify node, npm, pnpm installation
node -v
npm -v

# Install pnpm
write-host "Installing pnpm"
npm install -g pnpm@$pnpmVersion
pnpm --version

# GIT clone and checkout part
if (-not (Command-Exists "git version")) {
    # Download and install Git
    write-host "Installing git"
    if (-not (Test-Path -Path "$toolsInstallDir\git" -PathType Container)) {
        Invoke-WebRequest -Uri "https://github.com/git-for-windows/git/releases/download/v2.42.0.windows.2/MinGit-$gitVersion-64-bit.zip" -OutFile "$toolsInstallDir\git.zip"
        Expand-Archive -Path "$toolsInstallDir\git.zip" -DestinationPath "$toolsInstallDir\git"
    }
    $env:Path += ";$toolsInstallDir\git\cmd"
}

# Install WSL if requested
if ($installWSL -eq "1") {
    Write-Host "Checking WSL installation..."
    wsl -l -v
    $installed = $?
    if (!$installed) {
        Write-Host "Installing WSL2..."
        wsl --set-default-version 2
        wsl --install --no-distribution
        $distroMissing = $?
        if ($distroMissing) {
            Write-Host "WSL enabled, but distro is missing. Installing default distro..."
            wsl --install --no-launch
        }
    }
}

if (-not (Command-Exists "podman")) {
    write-host "Podman is not installed, installing..."
    # Download and install the (nightly) podman for windows
    if (-not [string]::IsNullOrWhiteSpace($podmanDownloadUrl)) {

        # Installation of the zip podman achive
        $extension = [IO.Path]::GetExtension($podmanDownloadUrl)
        $podmanProgramFiles="$env:ProgramFiles\RedHat\Podman\"
        $podmanPath=""
        $useUserScope=$false  # Track whether to use User or Machine scope for PATH
        if ($extension -eq '.zip') {
            $podmanFolder="podman-remote-release-windows_amd64"
            write-host "Downloading podman archive from $podmanDownloadUrl"
            if (-not (Test-Path -Path "$toolsInstallDir\podman" -PathType Container)) {
                Invoke-WebRequest -Uri $podmanDownloadUrl -OutFile "$toolsInstallDir\podman.zip"
                mkdir -p "$toolsInstallDir\podman"
                Expand-Archive -Path "$toolsInstallDir\podman.zip" -DestinationPath "$toolsInstallDir\podman" -Force
            }
            # we need to find out the folder name extracted from archive, could be podman-5.1.0 or podman-5.2.0-dev
            $podmanFolderName=ls "$toolsInstallDir\podman" -Name
            write-host "Extracted Podman Installation folder found: $podmanFolderName"
            $podmanPath="$toolsInstallDir\podman\$podmanFolderName\usr\bin"
            $useUserScope=$true  # ZIP installs to user directory
            # To use gvproxy from achived installation, Path solution does not exist
            # See , set the helper_binaries_dir key in the `[engine]` section of containers.conf
            # We need to either use podman_helper_dir or place binaries at "C:\Program Files\RedHat\Podman\"
            # For now only for hyperv
            if (-not [string]::IsNullOrWhiteSpace($podmanProvider) -and $podmanProvider -eq "hyperv") {
                if (-not (Test-Path -Path $podmanProgramFiles)) {
                    write-host "Copying podman binary helper files into program files..."
                    $command="New-Item -ItemType Directory -Path '$podmanProgramFiles'"
                    #Start-Process powershell.exe -ArgumentList "-NoProfile", "-ExecutionPolicy Bypass", "-Command $command" -Verb RunAs -Wait
                    Invoke-Admin-Command -Command $command -WorkingDirectory $(pwd) -Privileged "1" -TargetFolder $targetLocationTmpScp
                    $commandCopy="Copy-Item -Path '$podmanPath\*' -Destination '$podmanProgramFiles'"
                    #Start-Process powershell.exe -ArgumentList "-NoProfile", "-ExecutionPolicy Bypass", "-Command $commandCopy" -Verb RunAs -Wait
                    Invoke-Admin-Command -Command $commandCopy -WorkingDirectory $(pwd) -Privileged "1" -TargetFolder $targetLocationTmpScp
                }
            }
        } elseif ($extension -eq '.exe') {
            write-host "Downloading podman setup.exe from $podmanDownloadUrl"
            Invoke-WebRequest -Uri $podmanDownloadUrl -OutFile "$toolsInstallDir\podman.exe"
            # Install the setup.exe
            write-host "Install Podman from setup.exe silently.."
            $process = Start-Process -FilePath "$toolsInstallDir\podman.exe" -ArgumentList "/S" -PassThru -Wait
            write-host "Install process exit code: " $process.ExitCode
            if ($process.ExitCode -eq 1618) {
                write-host "Re-trying Podman installation later, another installation is in progress"
                Start-Sleep -Seconds 60
                $process = Start-Process -FilePath "$toolsInstallDir\podman.exe" -ArgumentList "/S" -PassThru -Wait
                write-host "Second install process exit code: " $process.ExitCode
            }
            # It seems that we need to put installed podman path on the system PATH in order for podman to be accessible in the session
            $podmanPath=$podmanProgramFiles
            $useUserScope=$false  # EXE installs to Program Files (system-wide)
        } elseif ($extension -eq '.msi') {
            write-host "Downloading podman MSI installer from $podmanDownloadUrl"
            Invoke-WebRequest -Uri $podmanDownloadUrl -OutFile "$toolsInstallDir\podman.msi"
            # Install MSI using user-scope installation (default, no admin required)
            write-host "Installing Podman MSI silently..."
            $msiLogFile = "$targetLocation\podman-msi.log"
            $msiArgs = @("/package", "$toolsInstallDir\podman.msi", "/quiet", "/l*v", $msiLogFile)
            $process = Start-Process msiexec.exe -ArgumentList $msiArgs -PassThru -Wait
            write-host "Install process exit code: " $process.ExitCode
            if ($process.ExitCode -ne 0) {
                if (Test-Path $msiLogFile) {
                    write-host "MSI Installation Log:"
                    Get-Content $msiLogFile | ForEach-Object { write-host $_ }
                }
                Throw "Podman MSI installation failed with exit code: $($process.ExitCode). Check log above for details."
            }
            # MSI user-scope installation path
            $podmanPath="$env:LOCALAPPDATA\Programs\Podman\"
            $useUserScope=$true  # MSI installs to user directory (no admin required)
        }

        if (Test-Path -Path $podmanPath) {
            # Add to current session PATH unless it is there already
            $env:Path += ";$podmanPath"
            
            # Set PATH persistently based on installation type
            if ($useUserScope) {
                # User-scope installation (ZIP, MSI) - no admin required
                write-host "Adding Podman location: $podmanPath, on the User PATH"
                write-host "Setting $podmanPath on PATH with User scope"
                $currentUserPath = [Environment]::GetEnvironmentVariable('Path', 'User')
                if (-not $currentUserPath.Contains($podmanPath)) {
                    [Environment]::SetEnvironmentVariable('Path', ($currentUserPath + ';' + $podmanPath), 'User')
                }
                write-host "User PATH updated: $([Environment]::GetEnvironmentVariable('Path', 'User'))"
            } else {
                # System-wide installation (EXE) - requires admin
                write-host "Adding Podman location: $podmanPath, on the System PATH"
                write-host "Setting $podmanPath on PATH with Machine scope"
                $command="[Environment]::SetEnvironmentVariable('Path', (`$Env:Path + ';$podmanPath'), 'MACHINE')"
                Start-Process powershell.exe -ArgumentList "-NoProfile", "-ExecutionPolicy Bypass", "-Command $command" -Verb RunAs -Wait
                write-host "$([Environment]::GetEnvironmentVariable('Path', 'MACHINE'))"
            }

            # store the podman installation
            cd "$workingDir\$resultsFolder"
            write-host "Podman installation path will be stored in $outputFile"
            "'$podmanPath'" | Out-File -FilePath $outputFile -NoNewline
            podman -v
        } else {
            Write-Host "The path $podmanPath does not exist, verify downloadUrl and version"
            Throw "Expected Podman Path: $podmanPath does not exist"
        }
    } else {
        Write-Host "Podman not found and no download URL provided"
    }
} else {
    write-host "Podman is already installed on the system"
    podman -v
}

# If the provider is hyperv, we need to allow podman in defender's firewall
if (-not [string]::IsNullOrWhiteSpace($podmanProvider) -and $podmanProvider -eq "hyperv") {
    write-host "Enable podman (with hyperv) to send and receive requests through the firewall"
    $commandPath=$(get-command podman).Path
    $inbound="New-NetFirewallRule -DisplayName 'podman' -Direction Inbound -Program $commandPath -Action Allow -Profile Private"
    $outbound="New-NetFirewallRule -DisplayName 'podman' -Direction Outbound -Program $commandPath -Action Allow -Profile Private"
    Start-Process powershell -verb runas -ArgumentList $inbound -wait
    Start-Process powershell -verb runas -ArgumentList $outbound -wait
}

# Setup podman machine in the host system
if ($initialize -eq "1") {
    $thisDir=$(pwd)
    $flags = ""
    if ($rootful -eq "1") {
        $flags += "--rootful "
    }
    if ($userNetworking -eq "1") {
        $flags += "--user-mode-networking "
    }
    $flags = $flags.Trim()
    $flagsArray = $flags -split ' '
    write-host "Initializing podman machine, command: podman machine init $flags"
    $logFile = "$workingDir\$resultsFolder\podman-machine-init.log"
    "podman machine init $flags" > $logFile
    if($flags) {
        # If more flag will be necessary, we have to consider composing the command other way
        # ie. https://stackoverflow.com/questions/6604089/dynamically-generate-command-line-command-then-invoke-using-powershell
        if (-not [string]::IsNullOrWhiteSpace($podmanProvider) -and $podmanProvider -eq "hyperv") {
            Write-Host "Initialize HyperV podman machine with flags ..."
            Invoke-Admin-Command -Command "podman machine init $flags" -WorkingDirectory $thisDir -EnvVarName "CONTAINERS_MACHINE_PROVIDER" -EnvVarValue "hyperv" -Privileged "1" -TargetFolder $targetLocationTmpScp
        } else {
            podman machine init $flagsArray >> $logFile
        }
    } else {
        if (-not [string]::IsNullOrWhiteSpace($podmanProvider) -and $podmanProvider -eq "hyperv") {
            Write-Host "Initialize HyperV podman machine ..."
            Invoke-Admin-Command -Command "podman machine init" -WorkingDirectory $thisDir -EnvVarName "CONTAINERS_MACHINE_PROVIDER" -EnvVarValue "hyperv" -Privileged "1" -TargetFolder $targetLocationTmpScp
        } else {
            podman machine init >> $logFile
        }
    }
    if ($start -eq "1") {
        if (-not [string]::IsNullOrWhiteSpace($podmanProvider) -and $podmanProvider -eq "hyperv") {
            Write-Host "Starting HyperV Podman Machine ..."
            Invoke-Admin-Command -Command "podman machine start" -WorkingDirectory $thisDir -EnvVarName "CONTAINERS_MACHINE_PROVIDER" -EnvVarValue "hyperv" -Privileged "1" -TargetFolder $targetLocationTmpScp -WaitForCommand $false
        } else {
            write-host "Starting podman machine..."
            "podman machine start" >> $logFile
            podman machine start >> $logFile
        }
    }
    if (-not [string]::IsNullOrWhiteSpace($podmanProvider) -and $podmanProvider -eq "hyperv") {
        Write-Host "List HyperV Podman Machine ..."
        Invoke-Admin-Command -Command "podman machine ls" -WorkingDirectory $thisDir -EnvVarName "CONTAINERS_MACHINE_PROVIDER" -EnvVarValue "hyperv" -Privileged "1" -TargetFolder $targetLocationTmpScp
    } else {
        podman machine ls >> $logFile
    }

    ## Podman Machine smoke tests
    # the tests expect podman machine to be up
    if ($smokeTests -eq "1") {
        $testsLogFile = "$workingDir\$resultsFolder\podman-machine-tests.log"
        # TODO: include basic tests for podman machine verification 
    }
}


# checkout podman-desktop
Clone-Checkout $repo $fork $branch

if ($extTests -eq "1") {
    Clone-Checkout $extRepo $extFork $extBranch
}

# pnpm INSTALL AND TEST PART PODMAN-DESKTOP
$thisDir="$workingDir\podman-desktop"
cd $thisDir

# Execute the arbitrary code from external source
Execute-Scripts

write-host "Installing dependencies of podman-desktop"
pnpm install --frozen-lockfile 2>&1 | Tee-Object -FilePath 'output.log' -Append

# Running the e2e tests
if ($extTests -ne "1") {
    write-host "Running the e2e playwright tests using target: $npmTarget, binary used: $podmanDesktopBinary"
    if (-not [string]::IsNullOrWhiteSpace($podmanProvider) -and $podmanProvider -eq "hyperv") {
        Write-Host "Running tests with hyperv with admin privileges"
        Invoke-Admin-Command -Command "pnpm $npmTarget" -WorkingDirectory $thisDir -EnvVarName "CONTAINERS_MACHINE_PROVIDER" -EnvVarValue "hyperv" -Privileged "1" -TargetFolder $targetLocationTmpScp -WaitForCommand $false -WaitTimeout 7200 -SetSecrets "1"
    } elseif ($runAsAdmin -eq "1") {
        Write-Host "Running tests with admin privileges"
        Invoke-Admin-Command -Command "pnpm $npmTarget" -WorkingDirectory $thisDir -Privileged "1" -TargetFolder $targetLocationTmpScp -WaitForCommand $false -WaitTimeout 7200 -SetSecrets "1"
    } else {
        pnpm $npmTarget 2>&1 | Tee-Object -FilePath 'output.log' -Append
    }
    ## Collect results
    Collect-Logs "podman-desktop"
} else {
    write-host "Building podman-desktop to run e2e from extension repo"
    pnpm test:e2e:build 2>&1 | Tee-Object -FilePath 'output.log' -Append
}

## run extension e2e tests
if ($extTests -eq "1") {
    $thisDir="$workingDir\$extRepo"
    cd $thisDir
    write-host "Add latest version of the @podman-desktop/tests-playwright into right package.json"
    if (Test-Path "$workingDir\$extRepo\tests\playwright") {
        cd tests/playwright
    }
    pnpm add -D @podman-desktop/tests-playwright@next
    cd "$workingDir\$extRepo"
    write-host "Installing dependencies of $repo"
    pnpm install --frozen-lockfile 2>&1 | Tee-Object -FilePath 'output.log' -Append
    write-host "Running the e2e playwright tests using target: $npmTarget"
    if (-not [string]::IsNullOrWhiteSpace($podmanProvider) -and $podmanProvider -eq "hyperv") {
        Write-Host "Running tests with hyperv with admin privileges"
        Invoke-Admin-Command -Command "pnpm $npmTarget" -WorkingDirectory $thisDir -EnvVarName "CONTAINERS_MACHINE_PROVIDER" -EnvVarValue "hyperv" -Privileged "1" -TargetFolder $targetLocationTmpScp -WaitForCommand $false -WaitTimeout 7200 -SetSecrets "1"
    } elseif ($runAsAdmin -eq "1") {
        Write-Host "Running tests with admin privileges"
        Invoke-Admin-Command -Command "pnpm $npmTarget" -WorkingDirectory $thisDir -Privileged "1" -TargetFolder $targetLocationTmpScp -WaitForCommand $false -WaitTimeout 7200 -SetSecrets "1"
    } else {
        pnpm $npmTarget 2>&1 | Tee-Object -FilePath 'output.log' -Append
    }
    ## Collect results
    Collect-Logs $extRepo
}

# Cleaning up (secrets, env. vars.)
write-host "Purge env vars: $scriptEnvVars"
foreach ($var in $scriptEnvVars) {
    Remove-Item -Path "env:\$var"
}
if ($secretFile) {
    Write-Host "Remove secrets file $resourcesPath\$secretFile from the target"
    Remove-Item -Path "$resourcesPath\$secretFile"
}

# Cleaning up executables
$exeNames = @("docker-compose", "kubectl", "kind", "minikube", "crc") 
Write-host "Clean up executables: $exeNames"
foreach ($executable in $exeNames) {
    if(Command-Exists $executable) {
        Write-host "Removing $executable from path"
        $exePath = (Get-Command $executable).Source
        Remove-Item -Path $exePath
    } else {
        Write-host "$executable not found, nothing to remove."
    }
}

write-host "Script finished..."
