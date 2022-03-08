#!/bin/bash

for release in 16.04 18.04 20.04; do
    
    # sha256 file
    sha256file="https://cloud-images.ubuntu.com/releases/$release/release/SHA256SUMS"
    archivefile="ubuntu-$release-server-cloudimg-amd64-wsl.rootfs.tar.gz"
    archiveurl="https://cloud-images.ubuntu.com/releases/$release/release/$archivefile"
    buckettag="ubuntu:$release"

    # get sha256:
    sha256="$(curl -sL $sha256file | grep $archivefile | cut -d' ' -f1)"
    description="$(curl -sL --fail https://cloud-images.ubuntu.com/releases/$release/release/ | sed -n 's/<h1>\(.*\)<\/h1>/\1/Ip')"
    echo "$buckettag: $description, $sha256 - $archiveurl"
    bucketsha256=""
    
    bucketfile=bucket/ubuntu-$release.json
    [ -f "$bucketfile" ] || echo "$buckettag: Bucket file not found"
    [ -f "$bucketfile" ] && bucketsha256="$(jq -r '.[].sha256' $bucketfile)"

    if [ "$bucketsha256" = "$sha256" ]; then
        echo "$buckettag: Integrity checked"
    else
        # download:
        echo "Downloading $archiveurl"
        curl -L $archiveurl -o $archivefile
        # check download sha256:
        downloadsha256="$(sha256sum $archivefile | cut -d' ' -f1)"
        if  [ "$downloadsha256" != "$sha256" ]; then 
            echo "$buckettag: Download integrity ERROR: $downloadsha256 != $sha256"
            exit 2
        fi
        # compute size:
        archivesize="$(ls -lah $archivefile | awk -F " " {'printf "%sB\n", $5'} | sed 's/[0-9][0-9.]*/& /g')"
        rm -f $archivefile

        # update bucket file:
        bucket=$(cat <<JSON
{
    "$buckettag":
    {
    "source": "https://cloud-images.ubuntu.com",
    "date": "$(date +"%Y/%m/%d %H:%M:%S")",
    "description": "Official $description",
    "note": "",
    "archive": "$archiveurl",
    "sha256": "$sha256",
    "size": "$archivesize"
    }
}
JSON
)
        echo "$bucket" | tee $bucketfile
    fi
    echo
done

# Finally compose global register.json
find ./bucket -name "*.json" -exec cat {} \; | jq -M -s 'reduce .[] as $d ({}; . *=$d)' > register.json
cat register.json
