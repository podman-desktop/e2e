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
. "$scriptDir\common\windows\common.ps1"

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
            Download-PD('pd-setup.exe')
            write-host "Installing Podman Desktop from setup.exe file..."
            # run the installer
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
if (-not (Command-Exists "node -v")) {
    # Download and install the latest version of Node.js
    write-host "Installing node"
    # $nodejsLatestVersion = (Invoke-RestMethod -Uri 'https://nodejs.org/dist/index.json' | Sort-Object -Property version -Descending)[0].version
    if (-not (Test-Path -Path "$toolsInstallDir\node-$nodejsLatestVersion-win-x64" -PathType Container)) {
        Invoke-WebRequest -Uri "https://nodejs.org/dist/$nodejsLatestVersion/node-$nodejsLatestVersion-win-x64.zip" -OutFile "$toolsInstallDir\nodejs.zip"
        Expand-Archive -Path "$toolsInstallDir\nodejs.zip" -DestinationPath $toolsInstallDir
    }
    # we need to set node for local access in actually running script
    $env:Path += ";$toolsInstallDir\node-$nodejsLatestVersion-win-x64\"
    # Setting node to be available for the machine scope
    # requires admin access
    $command="[Environment]::SetEnvironmentVariable('Path', (`$Env:Path + ';$toolsInstallDir\node-$nodejsLatestVersion-win-x64\'), 'MACHINE')"
    Start-Process powershell.exe -ArgumentList "-NoProfile", "-ExecutionPolicy Bypass", "-Command $command" -Verb RunAs -Wait
    write-host "$([Environment]::GetEnvironmentVariable('Path', 'MACHINE'))"
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

# Podman Installation (if needed)
if ([string]::IsNullOrWhiteSpace($podmanPath)) {
    if (-not (Command-Exists "podman")) {
        if (-not [string]::IsNullOrWhiteSpace($podmanDownloadUrl)) {
            Write-Host "Podman not found, installing from $podmanDownloadUrl..."

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

            # Install Podman
            $extension = [IO.Path]::GetExtension($podmanDownloadUrl)
            $podmanProgramFiles = "$env:ProgramFiles\RedHat\Podman\"
            $useUserScope = $false

            if ($extension -eq '.zip') {
                # ZIP installation
                Write-Host "Installing from ZIP archive..."
                if (-not (Test-Path -Path "$toolsInstallDir\podman" -PathType Container)) {
                    Invoke-WebRequest -Uri $podmanDownloadUrl -OutFile "$toolsInstallDir\podman.zip"
                    mkdir -p "$toolsInstallDir\podman" | Out-Null
                    Expand-Archive -Path "$toolsInstallDir\podman.zip" -DestinationPath "$toolsInstallDir\podman" -Force
                }
                $podmanFolderName = Get-ChildItem "$toolsInstallDir\podman" -Name | Select-Object -First 1
                Write-Host "Extracted Podman folder: $podmanFolderName"
                $podmanPath = "$toolsInstallDir\podman\$podmanFolderName\usr\bin"
                $useUserScope = $true

                # For HyperV, copy binaries to Program Files
                if (-not [string]::IsNullOrWhiteSpace($podmanProvider) -and $podmanProvider -eq "hyperv") {
                    if (-not (Test-Path -Path $podmanProgramFiles)) {
                        Write-Host "Copying Podman helper binaries for HyperV..."
                        $command = "New-Item -ItemType Directory -Path '$podmanProgramFiles'"
                        Invoke-Admin-Command -Command $command -WorkingDirectory $(pwd) -Privileged "1" -TargetFolder $targetLocationTmpScp
                        $commandCopy = "Copy-Item -Path '$podmanPath\*' -Destination '$podmanProgramFiles'"
                        Invoke-Admin-Command -Command $commandCopy -WorkingDirectory $(pwd) -Privileged "1" -TargetFolder $targetLocationTmpScp
                    }
                }

            } elseif ($extension -eq '.exe') {
                # EXE installation
                Write-Host "Installing from EXE installer..."
                Invoke-WebRequest -Uri $podmanDownloadUrl -OutFile "$toolsInstallDir\podman.exe"
                Write-Host "Running Podman EXE installer silently..."
                $process = Start-Process -FilePath "$toolsInstallDir\podman.exe" -ArgumentList "/S" -PassThru -Wait
                Write-Host "Install process exit code: $($process.ExitCode)"
                if ($process.ExitCode -eq 1618) {
                    Write-Host "Another installation in progress. Retrying in 60 seconds..."
                    Start-Sleep -Seconds 60
                    $process = Start-Process -FilePath "$toolsInstallDir\podman.exe" -ArgumentList "/S" -PassThru -Wait
                    Write-Host "Second install attempt exit code: $($process.ExitCode)"
                }
                $podmanPath = $podmanProgramFiles
                $useUserScope = $false

            } elseif ($extension -eq '.msi') {
                # MSI installation
                Write-Host "Installing from MSI installer..."
                Invoke-WebRequest -Uri $podmanDownloadUrl -OutFile "$toolsInstallDir\podman.msi"
                Write-Host "Running Podman MSI installer silently..."
                $msiLogFile = "$targetLocation\podman-msi.log"
                $msiArgs = @("/package", "$toolsInstallDir\podman.msi", "/quiet", "/l*v", $msiLogFile)
                $process = Start-Process msiexec.exe -ArgumentList $msiArgs -PassThru -Wait
                Write-Host "Install process exit code: $($process.ExitCode)"
                if ($process.ExitCode -ne 0) {
                    if (Test-Path $msiLogFile) {
                        Write-Host "MSI Installation Log:"
                        Get-Content $msiLogFile | ForEach-Object { Write-Host $_ }
                    }
                    throw "Podman MSI installation failed with exit code: $($process.ExitCode)"
                }
                $podmanPath = "$env:LOCALAPPDATA\Programs\Podman\"
                $useUserScope = $true

            } else {
                throw "Unsupported file extension '$extension'. Expected .zip, .exe, or .msi"
            }

            # Verify and store installation path
            if (Test-Path -Path $podmanPath) {
                Write-Host "Podman installed at: $podmanPath"
                # Store installation path
                cd "$workingDir\$resultsFolder"
                "'$podmanPath'" | Out-File -FilePath "podman-location.log" -NoNewline
                cd $workingDir
            } else {
                throw "Expected Podman path does not exist: $podmanPath"
            }
        } else {
            Write-Host "Podman not found and no download URL provided"
        }
    } else {
        Write-Host "Podman already available on system"
    }
}

if (-not (Command-Exists "podman")) {
    if (Test-Path -Path "$podmanPath") {
        write-host "Adding Podman location: '$podmanPath', on the User PATH"
        #[System.Environment]::SetEnvironmentVariable('PATH', ([System.Environment]::GetEnvironmentVariable('PATH', 'User') + $podmanPath) -join ';', 'User')
        $env:Path += ";$podmanPath"
        # Make the podman available for the every scope (by using Machine scope)
        # write-host "Settings $podmanPath on PATH with Machine scope"
        # $command="[Environment]::SetEnvironmentVariable('Path', (`$Env:Path + ';$podmanPath'), 'MACHINE')"
        # Start-Process powershell.exe -ArgumentList "-NoProfile", "-ExecutionPolicy Bypass", "-Command $command" -Verb RunAs -Wait
        # write-host "$([Environment]::GetEnvironmentVariable('Path', 'MACHINE'))"
    } else {
        Write-Host "The path '$podmanPath' does not exist, verify downloadUrl and version"
        Throw "Expected Podman Path: '$podmanPath' does not exist"
    }
}

# Test podman version installed
podman -v

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
