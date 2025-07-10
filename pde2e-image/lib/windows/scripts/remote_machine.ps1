# Prepare remote machine powershell script
$podmanMachine="podman-machine"
$remoteMachine="remote-machine"
write-host "Preparing podman machine $podmanMachine"

podman machine init --now $podmanMachine

write-host "Podman Machine should be up and running:"
podman machine ls --format json

podman pull ghcr.io/podmandesktop-ci/alpine-remote

podman images

podman image exists podmandesktop-ci/alpine-remote; $?

$commandOut = $(podman image exists podmandesktop-ci/alpine-remote; $?)
if ( $commandOut -eq $false) {
    write-host "Image is not present on the machine"
    exit 1
} else {
    write-host "alpine-remote is present on the machine"
}

# Prepare the remote-machine for remote connection

# Get default system connection, load it from json
$json = podman system connection ls --format json | ConvertFrom-Json
foreach ($item in $json) { 
    if ($item.Default -match "True" ) { 
        $name=$($item.Name) 
        $uri=$($item.URI)
        $identity=$($item.Identity)
    }
}

write-host "Default connection - Name: $name, URI: $uri, Identity: $identity"

# Clean up the access to the podman machine
# Do not remove ~/.local/share/containers/podman as there are keys to the machine
podman system connection rm $podmanMachine
podman system connection rm $podmanMachine-root

# remove default connections and other podman related files fron APPDATA\containers
rm -r $env:APPDATA\containers\*

# remove other configuration files from USERPROFILE\.config\containers
rm -r $env:USERPROFILE\.config\containers

# create a connection from previous information
podman system connection add $remoteMachine --identity "$identity" "$uri"

# check connection
podman system connection ls --format json

# run the remote e2e tests...