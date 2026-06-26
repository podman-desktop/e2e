# Powershell script for podman setup
write-host "Podman Machine should be up and running:"
podman machine ls --format json

# variables
$tinyImage="quay.io/podman/hello:latest" # ~0'8MB
$smallImage="quay.io/sclorg/nginx-122-micro-c9s:20230718" # ~70MB
$mediumImage="docker.io/library/nginx:latest" # ~200MB
$largeImage="registry.access.redhat.com/ubi8/httpd-24-3:latest" # ~460MB

switch ($env:IMAGE_SIZE) {
    "tiny" {
        $testImage=$tinyImage
    }
    "small" {
        $testImage=$smallImage
    }
    "medium" {
        $testImage=$mediumImage
    }
    "large" {
        $testImage=$largeImage
    }
    default {
        Write-Host "IMAGE_SIZE '$env:IMAGE_SIZE' not found. Setting testImage to tinyImage"
        $testImage=$tinyImage
    }
}

# pull the image
Write-Host "Pulling image: $testImage"
podman pull $testImage

# repeat 100 times
Write-Host "Number of objects to generate => $env:OBJECT_NUM"
for ($imgNum = 1; $imgNum -le $env:OBJECT_NUM; $imgNum++) {
    # tag (in pd, effectively, copy)
    $taggedImage="localhost/my-image-$($imgNum):latest"
    Write-Host "Tagging image: $testImage as $taggedImage"
    podman tag $testImage $taggedImage
    
    # create container
    $containerName="my-container-$imgNum"
    Write-Host "Creating container: $containerName"
    podman run -d --name $containerName $taggedImage

    #create pod
    $podName="my-pod-$imgNum"
    Write-Host "Creating pod: $podName"
    podman pod create --name $podName
}

# run the stress tests...