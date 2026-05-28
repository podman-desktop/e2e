#!/bin/bash

# Versions variables
nodeVersion="v24.15.0"
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
extTests=0
extRepo=""
extFork=""
extBranch=""
npmTarget="test:e2e"
podmanPath=""
podmanDownloadUrl=""
podmanVersion=""
rootful=0
envVars=""
secretFile=""
podmanProvider=""
saveTraces=1
cleanMachine=1
scriptPaths=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --pdUrl) pdUrl="$2"; shift ;;
        --pdPath) pdPath="$2"; shift ;;
        --targetFolder) targetFolder="$2"; shift ;;
        --resultsFolder) resultsFolder="$2"; shift ;;
        --fork) fork="$2"; shift ;;
        --branch) branch="$2"; shift ;;
        --extRepo) extRepo="$2"; shift ;;
        --extTests) extTests="$2"; shift ;;
        --extFork) extFork="$2"; shift ;;
        --extBranch) extBranch="$2"; shift ;;
        --npmTarget) npmTarget="$2"; shift ;;
        --podmanPath) podmanPath="$2"; shift ;;
        --podmanDownloadUrl) podmanDownloadUrl="$2"; shift ;;
        --podmanVersion) podmanVersion="$2"; shift ;;
        --rootful) rootful="$2"; shift ;;
        --envVars) envVars="$2"; shift ;;
        --secretFile) secretFile="$2"; shift ;;
        --podmanProvider) podmanProvider="$2"; shift ;;
        --saveTraces) saveTraces="$2"; shift ;;
        --cleanMachine) cleanMachine="$2"; shift ;;
        --scriptPaths) scriptPaths="$2"; shift ;;
        *) ;;
    esac
    shift
done

# Functions
download_pd() {
    echo "Downloading Podman Desktop from $pdUrl"
    curl -L -O "$pdUrl"
}

echo "Reading envVars in script: '$envVars'"

# Create a env. vars from a string: VAR=VAL,VAR2=VAL
function load_variables() {
    echo "Loading Variables passed into image"
    echo "Env. Vars String: '$envVars'"
    # Check if the input string is not null or empty
    if [ -n "$envVars" ]; then
        # use input field separator
        IFS=',' read -ra VARIABLES <<< "$envVars"

        for var in "${VARIABLES[@]}"; do
            echo "Processing $var"
            # Split each variable definition
            IFS='=' read -r name value <<< "$var"

            # Check if the variable assignment is in VAR=Value format
            if [ -n "$value" ]; then
                # Set the environment variable
                export "$name"="$value"
                newValue="${!name}"
                script_env_vars+=("$name")
            else
                echo "Invalid variable assignment: $var"
            fi
        done
    else
        echo "Input string is empty."
    fi
    # check if we have explicit podman provider env. var. added
    if [ -n "$podmanProvider" ]; then
        echo "Settings CONTAINERS_MACHINE_PROVIDER: $podmanProvider"
        export CONTAINERS_MACHINE_PROVIDER=$podmanProvider
        script_env_vars+=("CONTAINERS_MACHINE_PROVIDER")
    fi
}

function execute_scripts() {
    echo "Loading Paths passed into image"
    echo "ScriptPaths String: '$scriptPaths'"

    # Check if the input string is not null or empty
    if [[ -n "$scriptPaths" ]]; then
        scripts_folder="$resourcesPath/scripts"

        # Split the input using comma separator
        IFS=',' read -r -a paths <<< "$scriptPaths"

        for path in "${paths[@]}"; do
            path=$(echo "$path" | xargs) # Trim whitespace
            echo "Processing $path"
            script_path="$scripts_folder/$path"

            if [[ -f "$script_path" ]]; then
                echo "Executing $script_path"
                bash "$script_path"
            else
                echo "$script_path does not exist"
            fi
        done
    fi
}

# Loading a secrets into env. vars from the file
function load_secrets() {
    if [ -n "$secretFile" ]; then
        secretFilePath="$resourcesPath/$secretFile"
        if [ -f $secretFilePath ]; then
            echo "Loading Secrets from file: $secretFilePath"
            if [ -f "$secretFilePath" ]; then
                while IFS='=' read -r key value || [ -n "$key" ]; do
                    # Ignore comments and empty lines
                    if [[ ! $key =~ ^\s*# && -n $key ]]; then
                        # Trim leading and trailing whitespaces
                        key=$(echo "$key" | sed 's/^[ \t]*//;s/[ \t]*$//')
                        value=$(echo "$value" | sed 's/^[ \t]*//;s/[ \t]*$//')
                        # Set the environment variable
                        export "$key"="$value"
                        script_env_vars+=("$key")
                    fi
                done < "$secretFilePath"
                echo "Secrets loaded from '$secretFilePath' and set as environment variables."
            else
                echo "File '$secretFilePath' not found."
            fi
        else
            echo "Secret File path $secretFilePath does not exist"
        fi
    else
        echo "Secret file Parameter not set"
    fi
}

function clone_checkout() {
    local_repo=$1
    local_fork=$2
    local_branch=$3
    echo "Working Dir: $workingDir"
    cd $workingDir
    echo "Cloning $local_repo"
    if [ -d $local_repo ]; then
        echo "$local_repo github repo exists"
    else
        repositoryURL="https://github.com/$local_fork/$local_repo.git"
        echo "Checking out $repositoryURL"
        git clone $repositoryURL
    fi

    cd $local_repo || exit
    echo "Fetching all branches and tags"
    git fetch --all
    echo "Checking out branch: $local_branch"
    git checkout $local_branch
}

function copy_exists() {
    local source=$1
    local target=$2
    if [ -e $source ]; then
        echo "Copying files from $source to $target"
        cp -r $source $target
    else
        echo "Path $source does not exist"
    fi
}

function collect_logs() {
    local folder="$1"
    mkdir -p "$workingDir/$resultsFolder/$folder"
    local source="$workingDir/$folder"
    local target="$workingDir/$resultsFolder/$folder"
    echo "Collecting the results from: $source, to: " $target

    local junits=()
    while IFS= read -r file; do
        # Only add to array if the file string is not empty
        [ -n "$file" ] && junits+=("$file")
    done < <(find "$source" -type f -name "junit*.xml" 2>/dev/null)

    local count=${#junits[@]}

    if [ "$count" -eq 0 ]; then
        echo "WARNING: No JUnit file found anywhere in $source"
    else
        if [ "$count" -gt 1 ]; then
            echo "WARNING: Expected exactly one JUnit file, but found $count! Proceeding with the first one."
        fi

        local junit="${junits[0]}"
        local target_path="$workingDir/$resultsFolder/junit-$folder.xml"

        echo "Found Junit file: $junit"
        echo "Copying $junit to $target_path"
        cp "$junit" "$target_path"
    fi

    if (( extTests == 1 )); then
        echo "Removing possible models from working directories"
        ls $source/**/output/**/*.gguf
        rm -rf $source/**/output/**/*.gguf
        echo "Removing possible VM files from **/images/*"
        ls $source/**/output/**/images/
        rm -rf $source/**/output/**/images/*
    fi

    ls $source/**/output/**/plugins/*
    rm -rf $source/**/output/**/plugins/*

    copy_exists "$source/output.log" $target
    copy_exists "$source/tests/output/" $target
    copy_exists "$source/tests/playwright/output/" $target
    copy_exists "$source/tests/playwright/tests/output/" $target
    # reduce the size of the artifacts
    # remove resources
    echo "Removing resources artifacts"
    rm -rf $target/resources
    rm -rf $target/*/resources
    rm -rf $target/**/resources
    echo "Removing plugins from pd home dir - contains node_modules"
    rm -rf $target/**/plugins/*
    # remove raw traces
    if [ -d "$target/traces" ]; then
        echo "Removing raw playwright trace files: ./**/traces/raw"
        rm -r "$target/traces/raw"
        if (( saveTraces == 0)); then
            echo "Removing all traces from test artifacts, mainly due capacity reasons"
            rm -rf "$target/traces"
        fi
    fi
}

# Adopt display variables from the GNOME session
# created by the separate display-setup task
function setup_display() {
    export DISPLAY=:0
    export GDK_BACKEND=x11

    local uid xauth_file
    uid=$(id -u)
    xdpyinfo &>/dev/null || true
    for i in $(seq 1 5); do
        xauth_file=$(ls "/run/user/$uid"/.mutter-Xwaylandauth.* 2>/dev/null | head -1)
        [[ -n "$xauth_file" ]] && break
        sleep 1
    done
    [[ -n "$xauth_file" ]] && export XAUTHORITY="$xauth_file" \
        || echo "WARNING: XAUTHORITY not found in /run/user/$uid"

    echo "Display: DISPLAY=$DISPLAY GDK_BACKEND=$GDK_BACKEND XAUTHORITY=$XAUTHORITY"
}


echo "Podman desktop E2E runner script is being run (RHEL)..."

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

# Redirect large caches off the small /home partition
export PLAYWRIGHT_BROWSERS_PATH="$workingDir/.cache/ms-playwright"
export PNPM_STORE_DIR="$workingDir/.pnpm-store"
export XDG_CONFIG_HOME="$workingDir/.config"
export XDG_DATA_HOME="$workingDir/.local/share"

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

# node installation
if ! command -v node &> /dev/null; then
    # architecture in [arm64, x86_64] -> node arch strings in [arm64, x64]
    if [ "$architecture" == "x86_64" ]; then
        nodeArch="x64"
    elif [ "$architecture" == "arm64" ]; then
        nodeArch="arm64"
    else
        echo "Error: Unsupported architecture $architecture"
        exit 1
    fi
    nodeDirName="node-$nodeVersion-linux-${nodeArch}"
    nodeUrl="https://nodejs.org/download/release/$nodeVersion/${nodeDirName}.tar.xz"

    # Check if Node.js is already installed
    echo "$(ls $toolsInstallDir)"
    if [ ! -d "$toolsInstallDir/$nodeDirName" ]; then
        # Download and install Node.js
        echo "Installing node $nodeVersion for linux $nodeArch"
        curl -o "$toolsInstallDir/node.tar.xz" "$nodeUrl"
        tar -xf "$toolsInstallDir/node.tar.xz" -C "$toolsInstallDir"
    fi
    if [ -d "$toolsInstallDir/$nodeDirName/bin" ]; then
        echo "Node Installation path found"
        export PATH="$PATH:$toolsInstallDir/$nodeDirName/bin"
    else
        echo "Node installation path not found"
        exit 1
    fi
fi

# node and npm version check
echo "Node.js Version: $(node -v)"
echo "npm Version: $(npm -v)"

if ! command -v git &> /dev/null; then
    echo "Installing git via dnf..."
    sudo dnf install -y git
fi

# git verification
git --version

# Install Electron/Podman Desktop runtime dependencies
echo "Installing Electron runtime dependencies..."
sudo dnf install -y \
    atk \
    at-spi2-atk \
    at-spi2-core \
    alsa-lib \
    cups-libs \
    gtk3 \
    libdrm \
    libXcomposite \
    libXdamage \
    libXfixes \
    libXrandr \
    libXtst \
    mesa-libgbm \
    nss \
    nspr \
    pango \
    xorg-x11-utils 2>/dev/null || true

# Adopt the display from the GNOME session created by the display-setup task
setup_display

# Install pnpm
echo "Installing pnpm"
npm install -g pnpm@$pnpmVersion
echo "pnpm Version: $(pnpm --version)"

# Podman Installation (if needed)
if [ -z "$podmanPath" ]; then
    if ! command -v podman &> /dev/null; then
        if [ -n "$podmanDownloadUrl" ]; then
            echo "Podman not found, installing from $podmanDownloadUrl..."

            # Download Podman
            toolsInstallDir="$HOME/tools"
            mkdir -p "$toolsInstallDir"
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

            else
                echo "Error: Unsupported file type '$fileType' for download URL. Expected ZIP."
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
            # RHEL: Install via dnf (default for RHEL when no download URL)
            echo "Installing Podman via dnf..."
            sudo dnf install -y podman
            podmanPath="/usr/bin"
            echo "$podmanPath" > "$workingDir/$resultsFolder/podman-location.log"
        fi
    else
        echo "Podman already available on system"
    fi
fi

# Setup Podman PATH
if ! command -v podman &> /dev/null; then
    if [ -n "$podmanPath" ]; then
        echo "Adding Podman to PATH: $podmanPath"
        export PATH="$PATH:$podmanPath"
    elif [ -d '/opt/podman/bin' ]; then
        echo "Podman is installed in /opt/podman/bin..."
        export PATH="$PATH:/opt/podman/bin"
    else
        echo "Podman is not installed, please install it first"
        exit 1
    fi
else
    if [ -n "$podmanPath" ]; then
        export PATH="$podmanPath:$PATH"
    fi
fi

podman -v

if (( cleanMachine == 1 )); then
    echo "Cleaning up the podman machines before running the tests..."
    echo "Check running podman processes..."
    if [ "$(pgrep podman | wc -l)" -gt 0 ]; then
        echo "Found running podman processes, terminating them..."
        pkill podman 2>/dev/null || true
    fi
    podman system prune -f --volumes 2>/dev/null || true
    # remove old podman system connections from user space
    rm -rf ~/.config/containers/podman-connections.json* 2>/dev/null || true
    rm -rf ~/.config/containers/podman 2>/dev/null || true
    echo "Cleanup finished..."
fi

# get running Podman Desktop instances and terminate them
exit_status=0
echo "pid of running Podman Desktop instances:"
pgrep -x "podman-desktop" || exit_status=$?
if (( exit_status == 0 )); then
    echo "Podman Desktop is running, terminating..."
    kill -9 $(pgrep -x "podman-desktop")
else
    echo "No running Podman Desktop"
fi

# Podman desktop binary
podmanDesktopBinary=""
appPath=""

if [ -z "$pdPath" ]; then
    if [ -n "$pdUrl" ]; then
        download_pd
        pkgFile=$(realpath $(find . -maxdepth 1 -name '*podman-desktop*' | head -1))
        echo "Downloaded package: $pkgFile"

        if [[ "$pkgFile" == *.tar.gz ]]; then
            echo "Extracting Podman Desktop tar.gz..."
            mkdir -p "$workingDir/podman-desktop-app"
            tar -xzf "$pkgFile" -C "$workingDir/podman-desktop-app"
            podmanDesktopBinary=$(find "$workingDir/podman-desktop-app" \
                -maxdepth 2 -name 'podman-desktop' -type f 2>/dev/null | head -1)
            if [ -z "$podmanDesktopBinary" ]; then
                podmanDesktopBinary=$(find "$workingDir/podman-desktop-app" \
                    -maxdepth 1 -type f -executable 2>/dev/null | head -1)
            fi
            appPath="$workingDir/podman-desktop-app"

        elif [[ "$pkgFile" == *.AppImage ]]; then
            echo "Using Podman Desktop AppImage..."
            sudo dnf install -y fuse 2>/dev/null || true
            chmod +x "$pkgFile"
            podmanDesktopBinary="$pkgFile"
            appPath="$pkgFile"

        elif [[ "$pkgFile" == *.rpm ]]; then
            echo "Installing Podman Desktop RPM: $pkgFile"
            sudo dnf install -y "$pkgFile"
            podmanDesktopBinary=$(which podman-desktop 2>/dev/null \
                || find /usr -name 'podman-desktop' -type f 2>/dev/null | head -1)
            appPath="rpm"

        else
            echo "Error: Unknown Podman Desktop package format: $pkgFile"
            exit 1
        fi

        if [ -z "$podmanDesktopBinary" ]; then
            echo "Error: Could not determine Podman Desktop binary path after extraction"
            exit 1
        fi
        echo "Podman Desktop binary: $podmanDesktopBinary"
        chmod +x "$podmanDesktopBinary" 2>/dev/null || true
    fi
else
    podmanDesktopBinary="$pdPath"
fi

if [ -n "$podmanDesktopBinary" ]; then
    echo "Setting PODMAN_DESKTOP_BINARY to: $podmanDesktopBinary"
    export PODMAN_DESKTOP_BINARY="$podmanDesktopBinary"
elif (( extTests == 1 )); then
    echo "Setting PODMAN_DESKTOP_ARGS to: $workingDir/podman-desktop"
    export PODMAN_DESKTOP_ARGS="$workingDir/podman-desktop"
fi

export CI=true
testsOutputLog="$workingDir/$resultsFolder/tests.log"

# Checkout Podman Desktop only if necessary
if [[ "$extTests" -eq 1 ]] && [ -n "$podmanDesktopBinary" ] ; then
    echo "Running ext. tests and podman Desktop binary is specified, skipping checkout for podman-desktop"
else
    echo "Checking out Podman Desktop repository"
    clone_checkout "podman-desktop" $fork $branch
    cd "$workingDir/podman-desktop"
    echo "Installing dependencies and storing pnpm run output in: $testsOutputLog"
    pnpm install --frozen-lockfile 2>&1 | tee -a $testsOutputLog
    # extract since tests should be run after execute scripts
    if [[ "$extTests" -eq 1 ]]; then
        echo "Building podman-desktop for extension e2e tests"
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
    collect_logs "podman-desktop"
fi

# Cleaning up, env vars - secrets
echo "Cleaning the host"
unset "${script_env_vars[@]}"

# Remove secrets file
if [ -f "$resourcesPath/$secretFile" ]; then
    echo "Removing secrets file: $resourcesPath/$secretFile"
    rm "$resourcesPath/$secretFile"
fi

if (( cleanMachine == 1 )); then
    echo "Cleaning up podman"
    podman system prune -f --volumes 2>/dev/null || true
fi

if [ -n "$appPath" ]; then
    if [ "$appPath" = "rpm" ]; then
        echo "Removing Podman Desktop RPM installation"
        sudo dnf remove -y podman-desktop 2>/dev/null || true
    elif [ -d "$appPath" ]; then
        echo "Removing extracted Podman Desktop: $appPath"
        rm -rf "$appPath"
    elif [ -f "$appPath" ]; then
        echo "Removing Podman Desktop AppImage: $appPath"
        rm -f "$appPath"
    fi
fi

# Remove binaries
binaries=("docker-compose" "kubectl" "kind" "minikube")
for binary in "${binaries[@]}";
do
    binaryPath=$(which "$binary" 2>/dev/null)
    if [ -f "$binaryPath" ]; then
        echo "Removing $binary binary file"
        sudo rm "$binaryPath"
    fi
done

echo "Script finished..."
