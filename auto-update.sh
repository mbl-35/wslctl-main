#!/bin/sh
SDIR=$(cd -- "$(dirname "$0")" && pwd) 


# ----------- TOOLS FCTS ------------------------------------------------------------
#fxargs() { local fct="$1"; shift; while read -r s; do $fct $s $@; done ; }
fxargs() {
    local pattern=""
    [ "$1" = "-I" ] && {  pattern="$2"; shift 2; } || \
        { pattern="!!"; set -- "$@" "$pattern"; }
    while read -r s; do 
        local cmd="${@//"$pattern"/"$s"}"
        $cmd
    done
}
error() { echo "ERROR: $@"; exit 1; }
verlte() { [  "$1" = "$(echo -e "$1\n$2" | sort -V | head -n1)" ] ; }
verlt() { [ "$1" = "$2" ] && return 1 || verlte $1 $2; }
vergt() { verlt "$2" "$1";}
vergte() { verlte "$2" "$1";}


# Converts a duration, like 10s, 5h, or 7m30s, to a number of seconds
# This parser is fairly lenient, but the only _supported_ format is:
#   ([0-9]+d)? *([0-9]+h)? *([0-9]+m)? *([0-9]+s)?
duration_to_seconds() {
    local input="$*" 
    local duration=0
    for element in $input; do
        if echo "$element" | grep -E -q "[[:space:]]*([0-9]+[smhd])$" >/dev/null ; then
            local value="$(echo $element | awk '{print substr($0,0,length-1)}')"
            local unit="$(echo $element | awk '{print substr($0,length,1)}')"
            local magnitude
            [ "$unit" = "s" ] && magnitude=1
            [ "$unit" = "m" ] && magnitude=60
            [ "$unit" = "h" ] && magnitude=3600
            [ "$unit" = "d" ] && magnitude=86400
            duration=$(expr $duration + $magnitude \* $value)
        else
            printf "Invalid duration: '%s' (token: %s)\n" "$*" "${input##* }" >&2
            return 1
        fi
    done
    echo "$duration"
}


octets_human_readable() {
    echo "$1" | awk '
        BEGIN { split("B,KB,MB,GB,TB", suff, ",") }
        {
            size=$1;
            rank=int(log(size)/log(1000));
            printf "%.3g %s\n", size/(1000**rank), suff[rank+1]
        }'
}

remote_content_size(){
  octets_human_readable $(\
    curl --head --location --silent "$1" | \
    awk '/[Cc]ontent-[Ll]ength/ {print $2}' \
    )
}

 __jstr=
json_init() { __jstr="{}"; }
json_load() { __jstr="$1"; }
json_load_file() { __jstr="$(jq . "$1")"; }
json_dump() { echo "${__jstr}" | jq -r '.'; }
json_keys() { echo "${__jstr}" | jq -r '.'$1' | keys[]'; }
json_values() { echo "${__jstr}" | jq -r '.'$1' | values[]'; }
json_select() { __jstr="$(echo "${__jstr}" |  jq -r  '.'$1'')"; }
json_get_var() { echo "${__jstr}" | jq -r  '.'$1''; }
json_set_var() {
    local key="$(echo "$1" | sed 's|\\|\\\\|')"; shift
    local val="$*"
    # Determine the type of the value
    if echo "$val" | grep -Eq '^[0-9]+$'; then                  # Number
        __jstr="$(echo "${__jstr}" | jq ".$key = $val" )"
    elif echo "$val" | grep -Eq '^\[(.*)\]$'; then              # Array (must be in JSON format)
        __jstr="$(echo "${__jstr}" | jq --argjson val "$val" ".$key = \$val"  )"
    elif echo "$val" | grep -Eq '^\{(.*)\}$'; then              # JSON Object (must be in JSON format)
        __jstr="$(echo "${__jstr}" | jq --argjson val "$val" ".$key = \$val"  )"
    elif [[ "$val" == "true" || "$val" == "false" ]]; then      # Boolean
        __jstr="$(echo "${__jstr}" | jq ".$key = $val"  )"
    elif [[ "$val" == "null" ]]; then
        __jstr="$(echo "${__jstr}" | jq ".$key = null"  )"
    else __jstr="$(echo "${__jstr}" | jq ".$key = \"$val\"" )"  # String (default)
    fi
}

__cache_mins=1440
cache_setup() { __cache_mins=$(expr $(duration_to_seconds "$1") / 60); }
cache_clear() { rm -rf "$(cache_dirpath)"; }
cache_cleanup() { find "$(cache_dirpath)" -type f -mmin +$__cache_mins -exec rm {} \; ; }
cache_filepath() { echo "$(cache_dirpath)/$1"; }
cache_dirpath() { local cache="$SDIR/.cache"; [ -d "$cache" ] || mkdir -p "$cache"; echo "$cache"; }
cache_exists() { cache_cleanup; test -f "$(cache_filepath $1)" ; }
cache_get() { local fn="$(cache_filepath "$1")"; [ ! -f "$fn" ] || cat "$fn"; }
cache() {
    local cache_name="$1"
    local fn="$(cache_filepath $cache_name)"
    shift
    if ! cache_exists "$cache_name"; then
        if [ -n "$1" ] && [ "$1" = "-" ]; then
            while IFS= read -r line; do 
                echo "$line" >> "$fn"
            done < /dev/stdin
        else 
            "$@" > "$fn"
        fi
    fi
    cache_get "$cache_name"
}


# check resuierements
which jq >/dev/null || error "jq tool requiered"
which curl >/dev/null || error "curl tool requiered"


# ----------- ALPINE ----------------------------------------------------------------
alpine_dl_cdn(){ echo "https://dl-cdn.alpinelinux.org/alpine"; }
ubuntu_dl_cdn(){ echo "https://cloud-images.ubuntu.com"; }

alpine_dl_cdn_release() { echo "$(alpine_dl_cdn)/v$1/releases/x86_64"; }

ubuntu_dl_cdn_release() { 
    local release="$1" dl dprefix=
    verlt "$release" "22.04" \
        && { dl="$(ubuntu_dl_cdn)/releases/$release"; dprefix="release-"; } \
        || { dl="$(ubuntu_dl_cdn)/wsl/releases/$release"; dprefix="" ; }
    [ -n "$2" ] \
        && echo "$dl/$dprefix$2" \
        || echo "$dl"
    }

ubuntu_dl_codenames() {
    cache ubuntu_codenames curl -sL --fail \
        "https://git.launchpad.net/ubuntu/+source/distro-info-data/plain/ubuntu.csv"
}

ubuntu_codename(){
    local codename="$(ubuntu_dl_codenames | grep -E "^$1" | cut -d ',' -f 3 )" 
    [ -z "$codename" ] && error "Ubuntu codename not found for '$1'"
    echo "$codename"
}

ubuntu_codename_full(){
    local codename="$(ubuntu_dl_codenames | grep -E "^$1" | cut -d ',' -f 2 )" 
    [ -z "$codename" ] && error "Ubuntu codename not found for '$1'"
    echo "$codename"
}

ubuntu_is_lts() { [ "$1" != "${1%".04"}" ] && [ "$(( ${1%.*} % 2))" -eq 0 ] && return 0 ; }


# get all available Alpine release - ouput '3.5 3.6 ...'
alpine_releases(){
    local regex='>v[[:digit:]]+\.[[:digit:]]+/<'
    cache alpine_releases_dl curl -sL --fail "$(alpine_dl_cdn)" \
        | grep -E $regex | sed -e 's/<[^>]*>//g' | sort -V | sed 's#/.*##g; s/[^0-9.]//'
}
ubuntu_releases(){
    local regex='>[[:digit:]]+\.[[:digit:]]+/<'
    cache ubuntu_releases_dl curl -sL --fail "$(ubuntu_dl_cdn)/releases" \
        | grep -E $regex | sed -e 's/<[^>]*>//g' | sort -V | sed 's#/.*##g; s/[^0-9.]//'
}

# get all minirootfs (used for wsl) available for each release
alpine_wsl_scan(){
    local release="$1"
    local full_scan=${2:-true}
    local cache_name="alpine_$release"

    local dl_release="$(alpine_dl_cdn_release $release)"
    local regex='>alpine-minirootfs-[[:digit:]]+\.[[:digit:]]+\.[[:digit:]]+-x86_64.tar.gz<'

    # {archive_name} {build_date} {build_hour} {size}
    while IFS=' ' read -r wsl_file build_date build_hour size ; do
        local sha256 descr 

        local release_name="$(echo "$wsl_file" | sed 's/.*-\([0-9\.][0-9\.]*\).*/\1/')"
        # convert 14-Apr-2021 => 2021/04/14
        build_date="$(echo "$build_date" | awk '{
            # convert 14-Apr-2021 => 2021/04/14
            months="  JanFebMarAprMayJunJulAugSepOctNovDec"
            split($1,d,"-")
            printf("%04d/%02d/%02d", d[3], index(months, d[2])/3, d[1])
            '} )"
        build_hour="${build_hour}:00"
        sha256="$(cache "alpine_${release_name}_sha256_dl" \
            curl -sL --fail "$dl_release/$wsl_file.sha256" | cut -f 1 -d " "
            )"
        release_date="$(echo "$build_date" | sed 's|/||g' )"
        desc="$(echo "Official Alpine Release $release_name [$release_date]" | sed 's/  */_/g' )"

        echo "alpine $release $dl_release/$wsl_file $build_date $build_hour $size $sha256 $desc"
        $full_scan || break

    done < <(cache "$cache_name"_dl curl -sL --fail "$dl_release" \
        | grep -E $regex | sed -e 's/<[^>]*>//g' | sort -V \
        | sed 's|^/||;s/\r$//;s/  */ /g' | tac )

    }

ubuntu_wsl_scan_release_date(){
    local release="$1"
    local release_date="$2"
    local cache_name="ubuntu_${release}_$release_date"
    local codename="$(ubuntu_codename_full "$release")"
    local lts_flag=""
    ubuntu_is_lts "$release" && lts_flag="LTS"

    # {release} {archive_url} {build_date} {build_hour} {size} {sha256} {_desc_}
    local dl_release_date="$(ubuntu_dl_cdn_release "$release" "$release_date")"

    while IFS=' ' read -r sha256 wsl_file; do
        local wsl_file_info build_date build_hour size descr

        wsl_file_info="$(cache "ubuntu_${release}_index_dl" \
            curl -sL --fail $dl_release_date \
            | grep "$wsl_file" \
            | sed -e 's/<[^>]*>//g' -e 's/ +/ /g')"
        build_date="$(echo $wsl_file_info | awk '{
            dmap="  JanFebMarAprMayJunJulAugSepOctNovDec"
            split($2,d,"-")
            if (index(dmap,d[2]) == 0)
                printf("%04d/%02d/%02d", d[1], d[2], d[3])
            else
                printf("%04d/%02d/%02d", d[3], index(dmap,d[2])/3, d[1])
            }')"
        build_hour="$(echo $wsl_file_info | awk '{ print $3 ":00" }')"
        size="$(echo $wsl_file_info | awk '{ print $4 }')"
        descr="$(echo "Official Ubuntu $release $lts_flag ($codename) [$release_date]" | sed 's/  */_/g' )"

        echo "$release $dl_release_date/$wsl_file $build_date $build_hour $size $sha256 $descr"
    done < <(cache "$cache_name"_sha256_dl curl -sL --fail \
                "$dl_release_date/SHA256SUMS" \
            | grep amd64-wsl.rootfs.tar.gz | sed 's|\*||g' )
}

ubuntu_wsl_scan(){
    local release="$1"
    local full_scan=${2:-true}
    local cache_name="ubuntu_$release"
    local dl_release="$(ubuntu_dl_cdn_release $release)"
    
    # ubuntu<=20.04 or 22.04+ (only lts)
    if verlt "$release" "22.04" || ubuntu_is_lts "$release" ; then
        
            # releases/{version}/release-{dates}+
            # wsl/releases/{version}/{dates}+
            while read release_date; do
                
                scan_info="$(ubuntu_wsl_scan_release_date "$release" "$release_date")"
                if [ ! -z "$scan_info" ]; then
                    echo "ubuntu $scan_info"
                    $full_scan || break
                fi

            done < <(cache "$cache_name"_dl curl -sL --fail "$dl_release" \
                | grep -E '[[:digit:]]{8}/<' | sed 's|.*\([0-9]\{8\}\)/.*|\1|' \
                | tac )
    else error "Unsupported Version $release"
    fi
}

# filtering available versions
alpine_wsl_version_filter() { verlt "$(echo "$1" | sed 's| .*||')" "3.13" || echo "$@"; }
ubuntu_wsl_version_filter() { ubuntu_is_lts "$1" && vergte "$1" "16.04" && echo "$@"; }

wsl_scan(){ ${1}_releases | fxargs ${1}_wsl_version_filter | fxargs -I {} ${1}_wsl_scan {} false ; }



_tojson(){
    # {distrib} {release} {archive_url} {build_date} {build_hour} {size} {sha256} {_desc_}
    json_init
    json_set_var '"'$1':'$2'".source' "https://$(echo "$3" | awk -F/ '{print $3}')"
    json_set_var '"'$1':'$2'".date' "$4 $5"
    json_set_var '"'$1':'$2'".description' "$(echo "$8" | sed 's|_| |g')"
    json_set_var '"'$1':'$2'".note' ""
    json_set_var '"'$1':'$2'".archive' "$3"
    json_set_var '"'$1':'$2'".sha256' "$7"
    json_set_var '"'$1':'$2'".size' "$(remote_content_size $3)"
    json_dump
}


# ----------- MAIN ------------------------------------------------------------------
cache_setup "1d"
echo alpine ubuntu | \
    xargs -n 1 | \
    fxargs  wsl_scan | \
    fxargs _tojson | \
    jq -s 'add' \
    > "$SDIR/register.json"
