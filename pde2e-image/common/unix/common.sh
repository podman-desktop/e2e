#!/bin/bash
# Common bash utility functions for pde2e-image macOS scripts

# Detect file type and return MIME type
detect_file_type() {
    local file_path="$1"
    file -b --mime-type "$file_path"
}

# Add path to PATH environment variable if not already present
add_to_path() {
    local new_path="$1"
    if [[ ":$PATH:" != *":$new_path:"* ]]; then
        export PATH="$new_path:$PATH"
        echo "Added $new_path to PATH"
    else
        echo "$new_path already in PATH"
    fi
}

# Create directory if it doesn't exist
ensure_directory() {
    local dir_path="$1"
    if [ ! -d "$dir_path" ]; then
        echo "Creating directory: $dir_path"
        mkdir -p "$dir_path"
    fi
}

# Load environment variables from comma-separated string
load_variables() {
    echo "Loading Variables passed into image"
    echo "Env. Vars String: '$envVars'"
    # Check if the input string is not null or empty
    if [ -n "$envVars" ]; then
        # use input field separator
        IFS=',' read -ra VARIABLES <<< "$envVars"

        for variable in "${VARIABLES[@]}"; do
            echo "Processing $variable"
            # Split each variable definition
            IFS='=' read -r name value <<< "$variable"

            # Check if the variable assignment is in VAR=Value format
            if [ -n "$value" ]; then
                # Set the environment variable
                export "$name"="$value"
                newValue="${!name}"
                script_env_vars+=("$name")
            else
                echo "Invalid variable assignment: $variable"
            fi
        done
    else
        echo "Input string is empty."
    fi
    # check if we have explicit podman provider env. var. added
    # Darwin only for now
    if [ -n "$podmanProvider" ]; then
        echo "Settings CONTAINERS_MACHINE_PROVIDER: $podmanProvider"
        export CONTAINERS_MACHINE_PROVIDER=$podmanProvider
        script_env_vars+=("CONTAINERS_MACHINE_PROVIDER")
    fi
}

# Execute custom scripts from comma-separated paths
execute_scripts() {
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

# Load secrets from file into environment variables
load_secrets() {
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

# Clone repository and checkout specific branch
clone_checkout() {
    local_repo=$1
    local_fork=$2
    local_branch=$3
    local_git_provider_url="${4:-https://github.com}"
    echo "Working Dir: $workingDir"
    cd $workingDir
    echo "Cloning $local_repo"
    if [ -d $local_repo ]; then
        echo "$local_repo repo exists"
    else
        repositoryURL="$local_git_provider_url/$local_fork/$local_repo.git"
        echo "Checking out $repositoryURL"
        git clone $repositoryURL
    fi

    cd $local_repo || exit
    echo "Fetching all branches and tags"
    git fetch --all
    echo "Checking out branch: $local_branch"
    git checkout $local_branch
}

# Copy files if source exists
copy_exists() {
    local source=$1
    local target=$2
    if [ -e $source ]; then
        echo "Copying files from $source to $target"
        cp -r $source $target
    else
        echo "Path $source does not exist"
    fi
}

# Collect test logs and results
collect_logs() {
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
