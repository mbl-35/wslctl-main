#!/bin/bash

# ----------- ALPINE ----------------------------------------------------------------
for release in 3.13 3.14 3.15 3.16; do
    buckettag="alpine:$release"
    bucketfile=bucket/alpine-$release.json

    releaseIndexUrl="https://dl-cdn.alpinelinux.org/alpine/v$release/releases/x86_64/"
    releaseRegExp='>alpine-minirootfs-[[:digit:]]+\.[[:digit:]]+\.[[:digit:]]+-x86_64.tar.gz<'

    releaseLine="$(curl -sL --fail $releaseIndexUrl | grep -E $releaseRegExp | sed -e 's/<[^>]*>//g' |  sort --version-sort | tail -n1)"
    if [ -z "$releaseLine" ]; then
        echo "NO WSL Found for Alpine release $release"
        [ -f "$bucketfile" ] && rm $bucketfile
        continue
    fi

    echo "$releaseLine"
    #releaseLine="alpine-minirootfs-3.16.2-x86_64.tar.gz             09-Aug-2022 08:47             2720846"
    archivefile="$(echo "$releaseLine" | awk -F' ' '{ print $1 }')"
    archiveurl="$releaseIndexUrl$archivefile"
    latestRelease="$(echo "$releaseLine" | awk -F'-' '{ print $3 }')"
    latestReleaseDate="$(echo "$releaseLine" | awk -F' ' '{ print $2" "$3 }')"
    latestReleaseDateConverted=$(date -d"$latestReleaseDate" +%Y%m%d)

    sha256file="$releaseIndexUrl$archivefile.sha256"
    sha256="$(curl -sL $sha256file | cut -d' ' -f1)"


    description="Alpine Mini root filesystem $latestRelease [$latestReleaseDateConverted]"

    echo "$buckettag: $latestReleaseDate, $description, $sha256 - $archiveurl"
    bucketsha256=""
    
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
    "source": "https://alpinelinux.org/",
    "date": "$(date -d "$latestReleaseDate" +"%Y/%m/%d %H:%M:%S")",
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

# ----------- UBUNTU ----------------------------------------------------------------

for release in 16.04 18.04 20.04 22.04; do
    ubuntu_repo="https://cloud-images.ubuntu.com/releases/$release"
    archivefile="ubuntu-$release-server-cloudimg-amd64-wsl.rootfs.tar.gz"
    buckettag="ubuntu:$release"
    bucketfile=bucket/ubuntu-$release.json

    echo "..."

    # get latest build version containing wsl ...
    latest_build=latest_build_archive=latest_build_sha256=latest_build_description=latest_build_datetime=""
    for test_build in $(curl -sL --fail $ubuntu_repo/ | grep release- | sed 's/.*>release-\([0-9.]*\).*/\1/' | tac); do
        latest_build_base_url="$ubuntu_repo/release-$test_build"
        sha256file="$latest_build_base_url/SHA256SUMS"
        sha256="$(curl -sL $sha256file | grep $archivefile | cut -d' ' -f1)"
        if [ ! -z "$sha256" ]; then 
            latest_build="$test_build"
            latest_build_sha256="$sha256"
            latest_build_archive="$latest_build_base_url/$archivefile"
            latest_build_description="$(curl -sL --fail $latest_build_base_url/ | sed -n 's/<h1>\(.*\)<\/h1>/\1/Ip')"
            latest_build_datetime="$(curl -sL --fail $ubuntu_repo/ | grep release-$latest_build | sed 's/.*\([0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\} [0-9]\{2\}:[0-9]\{2\}\).*/\1/')"
            break
        fi
    done

    if [ -z "$sha256" ]; then 
        echo "NO WSL Found for release $release"
        [ -f "$bucketfile" ] && rm $bucketfile
        continue
    fi

    echo "release: $release edition: $latest_build"
    echo "sha256: $latest_build_sha256  url: $latest_build_archive" 
    echo "date: $latest_build_datetime"
    echo "description: $latest_build_description"

    # check integrity with already referenced
    [ -f "$bucketfile" ] || echo "$buckettag: Bucket file not found"
    [ -f "$bucketfile" ] && bucketsha256="$(jq -r '.[].sha256' $bucketfile)"

    if [ "$bucketsha256" = "$latest_build_sha256" ]; then
            echo "$buckettag: Integrity checked"
    else
        # download:
        echo "Downloading $latest_build_archive"
        curl -L $latest_build_archive -o $archivefile
        # check download sha256:
        downloadsha256="$(sha256sum $archivefile | cut -d' ' -f1)"
        if  [ "$downloadsha256" != "$latest_build_sha256" ]; then 
            echo "$buckettag: Download integrity ERROR: $downloadsha256 != $latest_build_sha256"
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
    "date": "$(date -d "$latest_build_datetime" +"%Y/%m/%d %H:%M:%S")",
    "description": "Official $latest_build_description",
    "note": "",
    "archive": "$latest_build_archive",
    "sha256": "$latest_build_sha256",
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
