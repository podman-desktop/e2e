# Common PowerShell utility functions for pde2e-image Windows scripts

# Function to check if a command is available
function Command-Exists($command) {
    $null = Get-Command -Name $command -ErrorAction SilentlyContinue
    return $?
}

# Download Podman Desktop
function Download-PD($fileName) {
    Write-Host "Downloading Podman Desktop from $pdUrl and saving to $fileName"
    curl.exe -L $pdUrl -o $fileName
}

# Copy files if source exists
function Copy-Exists($source, $target) {
    if (Test-Path -Path $source) {
        write-host "Copying all from $source"
        cp -r $source $target
    } else {
        write-host "$source does not exist"
    }
}

# Clone repository and checkout specific branch
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

# Load environment variables from comma-separated string
function Load-Variables() {
    Write-Host "Loading Variables passed into image"
    Write-Host "Input String: '$envVars'"

    write-host "Setting default env. var.: CI=true"
    Set-Item -Path "env:CI" -Value "true"
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

    # check if we have explicit podman provider env. var. added
    if (-not [string]::IsNullOrWhiteSpace($podmanProvider)) {
        Write-Host "Settings CONTAINERS_MACHINE_PROVIDER: $podmanProvider"
        Set-Item -Path "env:CONTAINERS_MACHINE_PROVIDER" -Value $podmanProvider
        $global:scriptEnvVars += "CONTAINERS_MACHINE_PROVIDER"
        $global:envVarDefs += "CONTAINERS_MACHINE_PROVIDER=$podmanProvider"
    }
}

# Execute custom scripts from comma-separated paths
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

# Load secrets from file into environment variables
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

# Collect test logs and results
function Collect-Logs($folder) {
    mkdir -p "$workingDir\$resultsFolder\$folder"
    $source="$workingDir\$folder"
    $target="$workingDir\$resultsFolder\$folder"
    write-host "Collecting the results from: $source, to: $target"

    # Find all JUnit files safely and force result into an array
    $junits = @(Get-ChildItem -Path $source -Filter "junit*.xml" -Recurse)
    $count = $junits.Count

    # Add the warning if accidental extras are found
    if ($count -gt 1) {
        write-host "WARNING: Expected exactly one JUnit file, but found $count! Proceeding with the first one found."
    }

    # Grab the first one found
    if ($count -gt 0) {
        $junit = $junits[0]
        write-host "Found Junit file: $($junit.FullName)"
        $target_path = "$workingDir\$resultsFolder\junit-$folder.xml"
        write-host "Copying $($junit.FullName) and renaming to $target_path"
        Copy-Item -Path $junit.FullName -Destination $target_path -Force
    } else {
        write-host "WARNING: No JUnit file found in $source"
    }

    if ($extTests -eq "1") {
        write-host "Removing possible models from working directories"
        Get-ChildItem -Path "$source" -Name "*.gguf" -Recurse | Remove-Item -Force
        write-host "Removing possible VM files from **/images/*"
        Get-ChildItem -Path "$source" -Name "images" -Directory -Recurse | Remove-Item -Recurse -Force
        write-host "Removing plugins from pd home dir - contains node_modules"
        Get-ChildItem -Path "$source" -Name "plugins" -Directory -Recurse | Remove-Item -Recurse -Force
        write-host "Removing safe-storage from pd home dir"
        Get-ChildItem -Path "$source" -Name "safe-storage" -Directory -Recurse | Remove-Item -Recurse -Force
        write-host "Removing browser resources from test artifacts"
        Get-ChildItem -Path "$source\browser\resources" -Directory -Recurse | Remove-Item -Recurse -Force
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
    if (Test-Path "$target\traces") {
        write-host "Removing raw playwright trace files: .\**\traces\raw"
        Get-ChildItem -Path "$target" -Name "raw" -Directory -Recurse | Where-Object { $_.Parent.Name -eq "traces" } | Remove-Item -Recurse -Force
        if ($saveTraces -eq "0") {
            write-host "Removing all traces from test artifacts, mainly due capacity reasons"
            Remove-Item -Path "$target\traces" -Recurse -Force
        }
    }
}

# Function to execute commands with optional admin privileges
function Invoke-Admin-Command {
    param (
        [string]$Command,            # Command to run (e.g., "pnpm install")
        [string]$WorkingDirectory,   # Working directory where the command should be executed
        [string]$TargetFolder,       # Target directory for storing the output/log files
        [string]$EnvVarName="",      # Environment variable name (optional)
        [string]$EnvVarValue="",     # Environment variable value (optional)
        [string]$Privileged='0',     # Whether to run command with admin rights, defaults to user mode,
        [string]$SetSecrets='0',     # Whether to process secret file and load it as env. vars., only in privileged mode,
        [int]$WaitTimeout=300,       # Default WaitTimeout 300 s, defines the timeout to wait for command execute
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
