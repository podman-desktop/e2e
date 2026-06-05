#!/bin/bash

###################################
# SCRIPT PARAMETERS
###################################

# Versions variables
nodeVersion="v24.15.0"
gitVersion="2.42.0"
pnpmVersion="10"

declare -a script_env_vars

# Source common functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/unix/common/common.sh"

pdUrl=""
pdPath=""
targetFolder=""
resultsFolder="results"
fork="podman-desktop"
branch="main"
repo="podman-desktop"
appName="Podman Desktop"
gitProviderUrl="https://github.com"
extTests=0
extRepo=""
extFork=""
extBranch=""
npmTarget="test:e2e"
podmanPath=""
initialize=0
start=0
rootful=0
envVars=""
secretFile=""
podmanProvider=""
saveTraces=1
cleanMachine=1
scriptPaths=""
podmanDownloadUrl=""
debugScript=0

while [[ $# -gt 0 ]]; do
    case $1 in
        --pdUrl) pdUrl="$2"; shift ;;
        --pdPath) pdPath="$2"; shift ;;
        --targetFolder) targetFolder="$2"; shift ;;
        --resultsFolder) resultsFolder="$2"; shift ;;
        --fork) fork="$2"; shift ;;
        --branch) branch="$2"; shift ;;
        --repo) repo="$2"; shift ;;
        --appName) appName="$2"; shift ;;
        --gitProviderUrl) gitProviderUrl="$2"; shift ;;
        --extRepo) extRepo="$2"; shift ;;
        --extTests) extTests="$2"; shift ;;
        --extFork) extFork="$2"; shift ;;
        --extBranch) extBranch="$2"; shift ;;
        --npmTarget) npmTarget="$2"; shift ;;
        --podmanPath) podmanPath="$2"; shift ;;
        --initialize) initialize="$2"; shift ;;
        --start) start="$2"; shift ;;
        --rootful) rootful="$2"; shift ;;
        --envVars) envVars="$2"; shift ;;
        --secretFile) secretFile="$2"; shift ;;
        --podmanProvider) podmanProvider="$2"; shift ;;
        --saveTraces) saveTraces="$2"; shift ;;
        --cleanMachine) cleanMachine="$2"; shift ;;
        --scriptPaths) scriptPaths="$2"; shift ;;
        --podmanDownloadUrl) podmanDownloadUrl="$2"; shift ;;
        --debugScript) debugScript="$2"; shift ;;
        *) ;;
    esac
    shift
done

####################################################################
# SCRIPT ENVIRONMENT INITIALIZATION
####################################################################

if [ "$debugScript" == "1" ]; then
    echo "DEBUG: Script parameters:"
    echo "pdUrl=$pdUrl"
    echo "pdPath=$pdPath"
    echo "targetFolder=$targetFolder"
    echo "resultsFolder=$resultsFolder"
    echo "fork=$fork"
    echo "branch=$branch"
    echo "repo=$repo"
    echo "appName=$appName"
    echo "gitProviderUrl=$gitProviderUrl"
    echo "extTests=$extTests"
    echo "extRepo=$extRepo"
    echo "extFork=$extFork"
    echo "extBranch=$extBranch"
    echo "npmTarget=$npmTarget"
    echo "podmanPath=$podmanPath"
    echo "initialize=$initialize"
    echo "start=$start"
    echo "rootful=$rootful"
    echo "envVars=$envVars"
    echo "secretFile=$secretFile"
    echo "podmanProvider=$podmanProvider"
    echo "saveTraces=$saveTraces"
    echo "cleanMachine=$cleanMachine"
    echo "scriptPaths=$scriptPaths"
    echo "podmanDownloadUrl=$podmanDownloadUrl"
    echo "debugScript=$debugScript"
fi

echo "Reading envVars in script: '$envVars'"

echo "E2E runner script is being run for $appName (repo: $repo)..."

if [ -z "$targetFolder" ]; then
    echo "Error: targetFolder is required"
    exit 1
fi

echo "Switching to a target folder: $targetFolder"
cd "$targetFolder" || exit
echo "Create a resultsFolder in targetFolder: $resultsFolder"
mkdir -p "$resultsFolder"
workingDir=$(pwd)
echo "Working location: $workingDir"

# Specify the user profile directory
userProfile="$HOME"

# Specify the shared tools directory
toolsInstallDir="$userProfile/tools"

# Output file for built podman desktop binary
outputFile="pde2e-binary-path.log"

# Determine the system's arch
architecture=$(uname -m)

resourcesPath=$workingDir

# Loading env. vars
load_variables

# load secrets
load_secrets

# Create the tools directory if it doesn't exist
if [ ! -d "$toolsInstallDir" ]; then
    mkdir -p "$toolsInstallDir"
fi

###########################################################
# TOOLS INSTALLATION
###########################################################

# Download application installer
download_app() {
    echo "Downloading application installer from $pdUrl"
    curl -L -o "app-installer.dmg" "$pdUrl"
}

# node installation
if ! command -v node &> /dev/null; then
    # architecture in [arm64, x86_64]
    # node arch strings in [arm64, x64]
    nodeArch=""
    if [ "$architecture" == "x86_64" ]; then
        nodeArch="x64"
    elif [ "$architecture" == "arm64" ]; then
        nodeArch="arm64"
    else
        echo "Error: Unsupported architecture $architecture"
        exit 1
    fi
    nodeUrl="https://nodejs.org/download/release/$nodeVersion/node-$nodeVersion-darwin-$nodeArch.tar.xz"

    # Check if Node.js is already installed
    echo "$(ls $toolsInstallDir)"
    if [ ! -d "$toolsInstallDir/node-$nodeVersion-darwin-$nodeArch" ]; then
        # Download and install Node.js
        echo "Installing node $nodeVersion for $architecture architecture"
        echo "curl -O $nodeUrl | tar -xJ -C $toolsInstallDir"
        curl -o "$toolsInstallDir/node.tar.xz" "$nodeUrl" 
        tar -xf $toolsInstallDir/node.tar.xz -C $toolsInstallDir
    fi
    if [ -d "$toolsInstallDir/node-$nodeVersion-darwin-${nodeArch}/bin" ]; then
        echo "Node Installation path found"
        export PATH="$PATH:$toolsInstallDir/node-$nodeVersion-darwin-${nodeArch}/bin"
    else
        echo "Node installation path not found"
    fi
else
    whereis node
    which node
    echo $PATH
fi

# node and npm version check
echo "Node.js Version: $(node -v)"
echo "npm Version: $(npm -v)"

if ! command -v git &> /dev/null; then
    # Check if Git is already installed
    if [ ! -d "$toolsInstallDir/git-$gitVersion" ]; then
        # Download and install Git
        echo "Installing git $gitVersion"
        gitUrl="https://github.com/git/git/archive/refs/tags/v$gitVersion.tar.gz"
        mkdir -p "$toolsInstallDir/git-$gitVersion"
        curl -O "$gitUrl" | tar -xz -C "$toolsInstallDir/git-$gitVersion" --strip-components 1
        cd "$toolsInstallDir/git-$gitVersion" || exit
        make prefix="$toolsInstallDir/git-$gitVersion" all
        make prefix="$toolsInstallDir/git-$gitVersion" install
    fi
    export PATH="$PATH:$toolsInstallDir/git-$gitVersion/bin"
fi

# git verification
git --version

# Install pnpm
echo "Installing pnpm"
sudo npm install -g pnpm@$pnpmVersion
echo "pnpm Version: $(pnpm --version)"

# Podman Installation (if needed)
if [ -z "$podmanPath" ]; then
    if ! command -v podman &> /dev/null; then
        if [ -n "$podmanDownloadUrl" ]; then
            echo "Podman not found, installing from $podmanDownloadUrl..."

            # Download Podman
            curl -o "$toolsInstallDir/podman-archive" -L "$podmanDownloadUrl"

            # Detect file type and install
            fileType=$(file -b --mime-type "$toolsInstallDir/podman-archive")
            echo "Archive file type: $fileType"

            if [ "$fileType" == "application/zip" ]; then
                # ZIP installation
                echo "Installing from ZIP archive..."
                [ -d "$toolsInstallDir/podman" ] && rm -rf "$toolsInstallDir/podman"
                mkdir -p "$toolsInstallDir/podman"
                mv "$toolsInstallDir/podman-archive" "$toolsInstallDir/podman.zip"
                unzip -o "$toolsInstallDir/podman.zip" -d "$toolsInstallDir/podman"
                podmanFolder=$(ls "$toolsInstallDir/podman")
                podmanPath="$toolsInstallDir/podman/$podmanFolder/usr/bin"

            elif [ "$fileType" == "application/x-xar" ]; then
                # PKG installation
                echo "Installing from PKG installer..."
                mv "$toolsInstallDir/podman-archive" "$toolsInstallDir/podman.pkg"
                sudo installer -pkg "$toolsInstallDir/podman.pkg" -target /
                podmanPath="/opt/podman/bin"

            else
                echo "Error: Unsupported file type '$fileType'. Expected ZIP or PKG."
                exit 1
            fi

            # Verify and store installation path
            if [ -e "$podmanPath" ]; then
                echo "Podman installed at: $podmanPath"
                echo "$podmanPath" > "$workingDir/$resultsFolder/podman-location.log"
            else
                echo "Error: Expected Podman path '$podmanPath' does not exist"
                exit 1
            fi
        else
            echo "Podman not found and no download URL provided"
        fi
    else
        echo "Podman already available on system"
    fi
fi

###########################################################
# ENVIRONMENT PREPARATION/CLEANUP
###########################################################

# Setup Podman
if ! command -v podman &> /dev/null; then
    if [ -n "$podmanPath" ]; then
        echo "Podman is not installed..."
        echo "Settings podman binary location '$podmanPath' to PATH"
        export PATH="$PATH:$podmanPath"
    elif [ -d '/opt/podman/bin' ]; then   
        echo "Podman is installed in /opt/podman/bin..."
        export PATH="$PATH:/opt/podman/bin"
    else
        echo "Podman is not installed, please install it first"
        exit 1
    fi
    echo "Check podman version..."
    podman -v
else
    echo "Warning: Podman is already installed..."
    # exit 1;
fi

if (( cleanMachine == 1 )); then
    echo "Cleaning up the podman machines before running the tests..."
    echo "Check running podman processes..."
    if [ "$(pgrep podman | wc -l)" -gt 0 ]; then
        echo "Found running podman processes, terminating them..."
        pkill podman
    fi
    if [ "$(pgrep crc | wc -l)" -gt 0 ]; then
        if [ -e "~/.crc/bin/crc" ]; then
            echo "Stopping and deleting crc..."
            ~/.crc/bin/crc stop
            ~/.crc/bin/crc delete -f
        fi
        echo "Found running crc processes, terminating them..."
        pkill crc
    fi
    # Reset Podman Machine
    podman machine reset -f
    # remove old podman system connections from user space
    rm -rf ~/.config/containers/podman-connections.json*
    rm -rf ~/.config/containers/podman
    echo "Cleanup finished..."
fi

# get running application instances and terminate them
exit_status=0
echo "pid of running $appName instances:"
pgrep -f "$appName" || exit_status=$?
if (( exit_status == 0 )); then
    echo "$appName is running, terminating..."
    kill -9 $(pgrep -f "$appName")
else
    echo "No running $appName"
fi

# Configure Podman Machine
if (( initialize == 1 )); then
    flags=""
    if (( rootful == 1 )); then
        flags+="--rootful "
    fi
    flags=$(echo "$flags" | awk '{$1=$1};1')
    flagsArray=($flags)
    echo "Initializing podman machine, command: podman machine init $flags"
    logFile="$workingDir/$resultsFolder/podman-machine-init.log"
    echo "podman machine init $flags" > "$logFile"
    if (( ${#flagsArray[@]} > 0 )); then
        podman machine init "${flagsArray[@]}" 2>&1 | tee -a "$logFile"
    else
        podman machine init 2>&1 | tee -a "$logFile"
    fi
    if (( start == 1 )); then
        echo "Starting podman machine..."
        echo "podman machine start --log-level=debug" >> "$logFile"
        podman machine start 2>&1 | tee -a "$logFile"
    fi
    podman machine ls --format json 2>&1 | tee -a "$logFile"
fi

# Podman desktop binary
podmanDesktopBinary=""
appPath=""

if [ -z "$pdPath" ]; then
    if [ -n "$pdUrl" ]; then
        download_app
        dmgPath="$workingDir/app-installer.dmg"
        if ! file "$dmgPath" | grep -q "zlib"; then
            echo "Error: Downloaded file is not a valid DMG image"
            file "$dmgPath"
            exit 1
        fi
        version=$(echo "$pdUrl" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')
        if [ -z "$version" ]; then
            echo "Warning: Could not extract version from URL, searching for app volume without version"
            pdVolumePath=$(find /Volumes -name "*${appName}*" -maxdepth 1 | head -1)
        else
            pdVolumePath=$(find /Volumes -name "*${appName} ${version}*" -maxdepth 1 | head -1)
        fi
        if ! hdiutil attach "$dmgPath"; then
            echo "Error: hdiutil attach failed - image not recognised"
            exit 1
        fi
        pdVolumePath=$(find /Volumes -name "*${appName} ${version}*" -maxdepth 1 | head -1)
        echo "Volume path: $pdVolumePath"
        sudo cp -R "$pdVolumePath/${appName}.app" /Applications
        hdiutil detach "$pdVolumePath"
        # codesign the extracted app
        appPath="/Applications/${appName}.app"
        # sudo codesign --force --deep --sign - "$appPath"
        codesign --verify --deep --verbose=2 "$appPath"
        podmanDesktopBinary="$appPath/Contents/MacOS/${appName}"
    fi
else
    podmanDesktopBinary="$pdPath"
fi

if [ -n "$podmanDesktopBinary" ]; then
    echo "Setting PODMAN_DESKTOP_BINARY to: $podmanDesktopBinary"
    export PODMAN_DESKTOP_BINARY="$podmanDesktopBinary"
elif (( extTests == 1 )); then
    echo "Setting PODMAN_DESKTOP_ARGS to: $workingDir/$repo"
    export PODMAN_DESKTOP_ARGS="$workingDir/$repo"
fi

###################################
# TESTS PREPARATION - GIT, DEPS
###################################

export CI=true
testsOutputLog="$workingDir/$resultsFolder/tests.log"
# Checkout repository only if necessary
if [[ "$extTests" -eq 1 ]] && [ -n "$podmanDesktopBinary" ] ; then
    echo "Running ext. tests and binary is specified, skipping checkout for $repo"
else
    echo "Checking out $repo repository"
    clone_checkout "$repo" "$fork" "$branch" "$gitProviderUrl"
    cd "$workingDir/$repo" || exit
    echo "Installing dependencies and storing pnpm run output in: $testsOutputLog"
    pnpm install --frozen-lockfile 2>&1 | tee -a $testsOutputLog
    # extract since tests should be run afte execute scripts
    if [[ "$extTests" -eq 1 ]]; then
        echo "Building $repo for extension e2e tests"
        pnpm test:e2e:build 2>&1 | tee -a $testsOutputLog
    fi
fi

# Checkout extension's repository
if [[ "$extTests" -eq 1 ]]; then
    echo "Checking out extension repository: $extRepo"
    clone_checkout $extRepo $extFork $extBranch
fi

# Execute the scripts
execute_scripts

###################################
# TESTS EXECUTION
###################################

## run extension e2e tests
if (( extTests == 1 )); then
    cd "$workingDir/$extRepo"
    echo "Add latest version of the @podman-desktop/tests-playwright into right package.json"
    if [ -d "$workingDir/$extRepo/tests/playwright" ]; then
        cd tests/playwright
    fi
    pnpm add -D @podman-desktop/tests-playwright@next
    cd "$workingDir/$extRepo"
    echo "Installing dependencies of $extRepo"
    pnpm install --frozen-lockfile 2>&1 | tee -a $testsOutputLog
    echo "Running the e2e playwright tests using target: $npmTarget"
    pnpm $npmTarget 2>&1 | tee -a $testsOutputLog
    ## Collect results
    collect_logs $extRepo
else
    echo "Running the e2e playwright tests using target: $npmTarget, binary path, if any: $podmanDesktopBinary"
    pnpm "$npmTarget" 2>&1 | tee -a $testsOutputLog
    collect_logs "$repo"
fi

###################################
# POST TEST - ENVIRONMENT CLEANUP
###################################

# Cleaning up, env vars - secrets
echo "Cleaning the host"
unset "${script_env_vars[@]}"

# Remove secrets file
if [ -f "$resourcesPath/$secretFile" ]; then
    echo "Removing secrets file: $resourcesPath/$secretFile"
    rm "$resourcesPath/$secretFile"
fi

if (( cleanMachine == 1 )); then
    echo "Cleaning up the podman machines"
    podman machine reset -f
fi

if [ -n "$podmanDesktopBinary" ]; then
    # removing installed app
    echo "Removing $appName app from /Applications"
    sudo rm -rf "$appPath"
fi

# Remove binaries
binaries=("docker-compose" "kubectl" "kind" "minikube" "crc")
for binary in "${binaries[@]}";
do
    binaryPath=$(which "$binary")
    if [ -f "$binaryPath" ]; then
        echo "Removing $binary binary file"
        sudo rm "$binaryPath"
    fi
done

echo "Script finished..."
