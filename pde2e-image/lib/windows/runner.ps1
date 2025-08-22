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
    [string]$extRepo = "podman-desktop-redhat-account-ext",
    [Parameter(HelpMessage = 'Extension Fork')]
    [string]$extFork = "redhat-developer",
    [Parameter(HelpMessage = 'Extension Branch')]
    [string]$extBranch = "main",
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
    [Parameter(HelpMessage = 'Run tests as admin')]
    $runAsAdmin = '0'
)

# Program Versions
$nodejsLatestVersion = "v22.14.0"
$gitVersion = '2.42.0.2'
$pnpmVersion = '10'

$global:scriptEnvVars = @()
$global:envVarDefs = @()

function Download-PD($fileName) {
    Write-Host "Downloading Podman Desktop from $pdUrl and saving to $fileName"
    curl.exe -L $pdUrl -o $fileName
}

# Function to check if a command is available
function Command-Exists($command) {
    $null = Get-Command -Name $command -ErrorAction SilentlyContinue
    return $?
}

function Copy-Exists($source, $target) {
    if (Test-Path -Path $source) {
        write-host "Copying all from $source"
        cp -r $source $target
    } else {
        write-host "$source does not exist"
    }
}

function Clone-Checkout($repo, $fork, $branch) {
    # clean up previous folder
    cd $workingDir
    write-host "Working Dir: " $workingDir
    write-host "Cloning " $repo
    if (Test-Path -Path $repo) {
        write-host "repository already exists"
    } else {
        # Clone the GitHub repository and switch to the specified branch
        $repositoryURL ="https://github.com/$fork/$repo.git"
        write-host "Checking out" $repositoryURL
        git clone $repositoryURL
    }
    # Checkout correct branch
    cd $repo
    write-host "Fetch all refs"
    git fetch --all
    write-host "checking out branch: $branch"
    git checkout $branch
}

# Loading variables as env. var from the CI into image
function Load-Variables() {
    Write-Host "Loading Variables passed into image"
    Write-Host "Input String: '$envVars'"

    write-host "Setting default env. var.: CI=true"
    Set-Item -Path "env:CI" -Value $true
    $global:scriptEnvVars += "CI"
    $global:envVarDefs += 'CI=true'

    write-host "Setting default env. var.: ROOTFUL_MODE=0"
    $rootfulMode='false'
    if ($rootful -eq '1') {
        $rootfulMode='true'
    }
    Set-Item -Path "env:ROOTFUL_MODE" -Value $rootfulMode
    $global:scriptEnvVars += "ROOTFUL_MODE"
    $global:envVarDefs += "ROOTFUL_MODE=$rootfulMode"

    # Set PODMAN_DESKTOP_BINARY if exists
    if($podmanDesktopBinary) {
        Set-Item -Path "env:PODMAN_DESKTOP_BINARY" -Value "$podmanDesktopBinary"
        $global:scriptEnvVars += "PODMAN_DESKTOP_BINARY"
        $global:envVarDefs += "PODMAN_DESKTOP_BINARY=$podmanDesktopBinary"
    } elseif ($extTests -eq "1") {
        Set-Item -Path "env:PODMAN_DESKTOP_ARGS" -Value "$workingDir\podman-desktop"
        $global:scriptEnvVars += "PODMAN_DESKTOP_ARGS"
        $global:envVarDefs += "PODMAN_DESKTOP_ARGS=$workingDir\podman-desktop"
    }
    # Check if the input string is not null or empty
    if (-not [string]::IsNullOrWhiteSpace($envVars)) {
        # Split the input using comma separator
        $variables = $envVars -split ','

        foreach ($variable in $variables) {
            # Split each variable definition
            $global:envVarDefs += $variable
            $parts = $variable -split '=', 2
            Write-Host "Processing $variable"

            # Check if the variable assignment is in VAR=Value format
            if ($parts.Count -eq 2) {
                $name = $parts[0].Trim()
                $value = $parts[1].Trim('"')

                # Set and test the environment variable
                Set-Item -Path "env:$name" -Value $value
                $global:scriptEnvVars += $name
            } else {
                Write-Host "Invalid variable assignment: $variable"
            }
        }
    } else {
        Write-Host "Input string is empty."
    }

}

# download and execute arbitrary script on the host
function Execute-Scripts() {
    Write-Host "Loading Paths passed into image"
    Write-Host "ScriptPaths String: '$scriptPaths'"
    # Check if the input string is not null or empty
    if (-not [string]::IsNullOrWhiteSpace($scriptPaths)) {
        $scriptsFolder="$resourcesPath"
        # Split the input using comma separator
        $paths = $scriptPaths -split ','

        foreach ($path in $paths) {
            $path = $path.Trim()
            # Split each variable definition
            Write-Host "Processing $path"
            $scriptPath="$scriptsFolder\$path"
            if (Test-Path $scriptPath) {
                write-host "Executing $scriptPath"
                if (-not [string]::IsNullOrWhiteSpace($podmanProvider) -and $podmanProvider -eq "hyperv") {
                    Invoke-Admin-Command -Command "& $scriptPath" -WorkingDirectory $thisDir -EnvVarName "CONTAINERS_MACHINE_PROVIDER" -EnvVarValue "hyperv" -Privileged "1" -TargetFolder $targetLocationTmpScp
                } else {
                    & "$scriptPath"
                }
            } else {
                write-host "$scriptPath does not exist"
            }
        }
    }
}

# Loading a secrets into env. vars from the file
function Load-Secrets() {
    if ($secretFile) {
        $secretFilePath="$resourcesPath/$secretFile"
        Write-Host "Loading Secrets from file: $secretFilePath"
        if (Test-Path $secretFilePath) {
            $properties = Get-Content $secretFilePath | ForEach-Object {
                # Ignore comments and empty lines
                if (-not $_.StartsWith("#") -and -not [string]::IsNullOrWhiteSpace($_)) {
                    # Split each line into key-value pairs
                    $key, $value = $_ -split '=', 2

                    # Trim leading and trailing whitespaces
                    $key = $key.Trim()
                    $value = $value.Trim()

                    # Set the environment variable
                    Set-Item -Path "env:$key" -Value $value
                    $global:scriptEnvVars += $key
                }
            }
            Write-Host "Secrets loaded from '$secretFilePath' and set as environment variables."
        } else {
            Write-Host "File '$secretFilePath' not found."
        }
    } else {
        write-host "There is no file with secrets, skipping..."
    }
}

function Collect-Logs($folder) {
    mkdir -p "$workingDir\$resultsFolder\$folder"
    $target="$workingDir\$resultsFolder\$folder"
    if ($extTests -eq "1") {
        write-host "Clean up models files..."
        Get-ChildItem -Path "$workingDir\$folder" *.gguf -Recurse | foreach { Remove-Item -Path $_.FullName }
    }
    write-host "Collecting the results into: " $target
    Copy-Exists $workingDir\$folder\stdout.txt $target
    Copy-Exists $workingDir\$folder\stderr.txt $target
    Copy-Exists $workingDir\$folder\tmp_script.ps1 $target
    Copy-Exists $workingDir\$folder\output.log $target
    Copy-Exists $workingDir\$folder\tests\output\* $target
    Copy-Exists $workingDir\$folder\tests\playwright\output\* $target
    Copy-Exists $workingDir\$folder\tests\playwright\tests\output\* $target
    Copy-Exists $workingDir\$folder\tests\playwright\tests\playwright\output\* $target
    # reduce the size of the artifacts
    if (Test-Path "$target\traces\raw") {
        write-host "Removing raw playwright trace files"
        rm -r "$target\traces\raw"
    }
}

function Invoke-Admin-Command {
    param (
        [string]$Command,            # Command to run (e.g., "pnpm install")
        [string]$WorkingDirectory,   # Working directory where the command should be executed
        [string]$TargetFolder,       # Target directory for storing the output/log files
        [string]$EnvVarName="",      # Environment variable name (optional)
        [string]$EnvVarValue="",     # Environment variable value (optional)
        [string]$Privileged='0',     # Whether to run command with admin rights, defaults to user mode,
        [string]$SetSecrets='0',     # Whether to process secret file and load it as env. vars., only in privileged mode,
        [int]$WaitTimeout=300,     # Default WaitTimeout 300 s, defines the timeout to wait for command execute
        [bool]$WaitForCommand=$true  # Wait for command execution indefinitely, default true, use timeout otherwise
    )

    cd $WorkingDirectory
    # Define file paths to capture output and error
    $outputFile = Join-Path -Path $WorkingDirectory -ChildPath "tmp_stdout_$([System.Datetime]::Now.ToString("yyyymmdd_HHmmss")).txt"
    $errorFile = Join-Path -Path $WorkingDirectory -ChildPath "tmp_stderr_$([System.Datetime]::Now.ToString("yyyymmdd_HHmmss")).txt"
    $tempScriptFile = Join-Path -Path $WorkingDirectory -ChildPath "tmp_script_$([System.Datetime]::Now.ToString("yyyymmdd_HHmmss")).ps1"

    # We need to create a local tmp script in order to execute it with admin rights with a Start-Process
    # We also want a access to the stdout and stderr which is not possible otherwise
    if ($Privileged -eq "1") {
        # Create the temporary script content
        $scriptContent = @"
# Change to the working directory
Set-Location -Path '$WorkingDirectory'

"@
        # If the environment variable name and value are provided, add to script
        if (![string]::IsNullOrWhiteSpace($EnvVarName) -and ![string]::IsNullOrWhiteSpace($EnvVarValue)) {
            $scriptContent += @"
# Set the environment variable
Set-Item -Path Env:\$EnvVarName -Value '$EnvVarValue'

"@
        }
        
        # If we have a set of env. vars. provided, add this code to script
        if (![string]::IsNullOrWhiteSpace($global:envVarDefs)) {
            Write-Host "Parsing Global Input env. vars in inline script: '$global:envVarDefs'"
            foreach ($definition in $global:envVarDefs) {
                # Split each variable definition
                Write-Host "Processing $definition"
                $parts = $definition -split '=', 2

                # Check if the variable assignment is in VAR=Value format
                if ($parts.Count -eq 2) {
                    $name = $parts[0].Trim()
                    $value = $parts[1].Trim('"')

                    # Set and test the environment variable
                    $scriptContent += @"
# Set the environment variable from array
Set-Item -Path Env:\$name -Value '$value'

"@
                } else {
                    Write-Host "Invalid variable assignment: $definition"
                }
            }
        }

        # Add secrets handling into tmp script
        if ($SetSecrets -eq "1") {
            Write-Host "SetSecrets flag is set"
            if ($secretFile) {
                Write-Host "SecretFile is defined and found..."
$scriptContent += @"
`$secretFilePath="$resourcesPath\$secretFile"
if (Test-Path `$secretFilePath) {
    `$properties = Get-Content `$secretFilePath | ForEach-Object {
        # Ignore comments and empty lines
        if (-not `$_.StartsWith("#") -and -not [string]::IsNullOrWhiteSpace(`$_)) {
            # Split each line into key-value pairs
            `$key, `$value = `$_ -split '=', 2

            # Trim leading and trailing whitespaces
            `$key = `$key.Trim()
            `$value = `$value.Trim()

            # Set the environment variable
            Set-Item -Path "env:`$key" -Value `$value
        }
    }
    Write-Host "Secrets loaded from '`$secretFilePath' and set as environment variables."
} else {
    Write-Host "File '`$secretFilePath' not found."
}

"@
            }
        }

        # Add the command execution to the script
        $scriptContent += @"
# Run the command and redirect stdout and stderr
# Try running the command and capture errors
try {
    'Executing Command: $Command' | Out-File '$outputFile' -Append
    $Command >> '$outputFile' 2>> '$errorFile'
    'Command executed successfully.' | Out-File '$outputFile' -Append
} catch {
    'Error occurred while executing command: ' + `$_.Exception.Message | Out-File '$errorFile' -Append
}

"@
        # Write the script content to the temporary script file
        write-host "Creating a content of the script:"
        write-host "$scriptContent"
        write-host "Storing at: $tempScriptFile"
        $scriptContent | Set-Content -Path $tempScriptFile

        # Start the process as admin and run the temporary script file
        $process = Start-Process powershell.exe -ArgumentList "-NoProfile", "-ExecutionPolicy Bypass", "-File", $tempScriptFile -Verb RunAs -PassThru
        $waitResult = $null
        if ($WaitForCommand) {
            write-host "Starting process with script awaiting until it is finished..."
            $waitResult = $process.WaitForExit()
        } else {
            write-host "Starting process with script awaiting for $WaitTimeout sec"
            $waitResult = $process.WaitForExit($WaitTimeout * 1000)
        }
        Write-Host "Process ID: $($process.Id)"
        if ($waitResult) {
            Write-Host "Process completed waiting successfully."
        } else {
            Write-Host "Process failed waiting after with exit code: $($process.ExitCode)"
        }

    } else {
        cd $WorkingDirectory
        # Run the command normally without elevated privileges
        if (![string]::IsNullOrWhiteSpace($EnvVarName) -and ![string]::IsNullOrWhiteSpace($EnvVarValue)) {
            "Settings Env. Var.: $EnvVarName = $EnvVarValue" | Out-File $outputFile -Append
            Set-Item -Path Env:\$EnvVarName -Value $EnvVarValue
        }
        Set-Location -Path '$WorkingDirectory'
        "Running the command: '$Command' in non privileged mode" | Out-File $outputFile -Append
        $output = Invoke-Expression $Command >> $outputFile 2>> $errorFile
    }

    # Copying logs and scripts back to the target folder (to get preserved and copied to the host)
    cp $tempScriptFile $TargetFolder
    cp $outputFile $TargetFolder
    cp $errorFile $TargetFolder

    # After the process finishes, read the output and error from the files
    if (Test-Path $outputFile) {
        Write-Output "Standard Output: $(Get-Content -Path $outputFile)"
    } else {
        Write-Output "No standard output..."
    }

    if (Test-Path $errorFile) {
        Write-Output "Standard Error: $(Get-Content -Path $errorFile)"
    } else {
        Write-Output "No standard error..."
    }
}

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
            $pdLocalAppData="$env:LOCALAPPDATA\Programs\podman-desktop"
            $pdPath="$pdLocalAppData\Podman Desktop.exe"
            write-host "Podman Desktop is installed on expected path: $pdLocalAppData"
            if (Test-Path -Path $pdPath -PathType Leaf) {
                write-host "Podman Desktop installation present..."
                mv "$pdPath" "$pdLocalAppData\pd.exe"
                write-host
                $podmanDesktopBinary="$pdLocalAppData\pd.exe"
            } else {
                write-host "Podman Desktop installation missing..."
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

# Set custom podman provider (wsl vs. hyperv)
if (-not [string]::IsNullOrWhiteSpace($podmanProvider)) {
    Write-Host "Setting CONTAINERS_MACHINE_PROVIDER: '$podmanProvider'"
    Set-Item -Path "env:CONTAINERS_MACHINE_PROVIDER" -Value $podmanProvider
    $global:scriptEnvVars += "CONTAINERS_MACHINE_PROVIDER"
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
        Invoke-Admin-Command -Command "pnpm $npmTarget" -WorkingDirectory $thisDir -EnvVarName "CONTAINERS_MACHINE_PROVIDER" -EnvVarValue "hyperv" -Privileged "1" -TargetFolder $targetLocationTmpScp -WaitForCommand $false -WaitTimeout 3600 -SetSecrets "1"
    } elseif ($runAsAdmin -eq "1") {
        Write-Host "Running tests with admin privileges"
        Invoke-Admin-Command -Command "pnpm $npmTarget" -WorkingDirectory $thisDir -Privileged "1" -TargetFolder $targetLocationTmpScp -WaitForCommand $false -WaitTimeout 3600 -SetSecrets "1"
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
        Invoke-Admin-Command -Command "pnpm $npmTarget" -WorkingDirectory $thisDir -EnvVarName "CONTAINERS_MACHINE_PROVIDER" -EnvVarValue "hyperv" -Privileged "1" -TargetFolder $targetLocationTmpScp -WaitForCommand $false -WaitTimeout 3600 -SetSecrets "1"
    } elseif ($runAsAdmin -eq "1") {
        Write-Host "Running tests with admin privileges"
        Invoke-Admin-Command -Command "pnpm $npmTarget" -WorkingDirectory $thisDir -Privileged "1" -TargetFolder $targetLocationTmpScp -WaitForCommand $false -WaitTimeout 3600 -SetSecrets "1"        
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
