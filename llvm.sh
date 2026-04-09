#!/usr/bin/env bash
################################################################################
# Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
# See https://llvm.org/LICENSE.txt for license information.
# SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
################################################################################
#
# This script will install the llvm toolchain on the different
# Debian and Ubuntu versions

# This script is stored on:
# https://github.com/opencollab/llvm-jenkins.debian.net/blob/master/llvm.sh

set -euxo pipefail


# --- Configuration & Constants ---

readonly LATEST_LLVM_VERSION='23'
readonly CURRENT_LLVM_STABLE='20'

declare -r -a NEEDED_BINARIES=('add-apt-repository' 'gpg' 'lsb_release')

readonly GPG_KEY_PATH='/etc/apt/trusted.gpg.d/apt.llvm.org.asc'
readonly GPG_KEY_URL='https://apt.llvm.org/llvm-snapshot.gpg.key'

# Mapping versions to repo suffixes
declare -A LLVM_VERSION_PATTERNS
setup_llvm_version_patterns
readonly LLVM_VERSION_PATTERNS

# Priority Tool Flags
declare -r -a CURL_COMMON=(--proto '=https' --tlsv1.2 --silent --show-error --fail --connect-timeout '10' --retry '3')
declare -r -a WGET_COMMON=(--quiet --retry-connrefused --timeout '10' --tries '3' --waitretry '4')
declare -r -a BUSYBOX_WGET_COMMON=(wget -q -O - -T '10')

# Default values
# Set default values for commandline arguments
#
BASE_URL="https://apt.llvm.org"
LLVM_VERSION="${CURRENT_LLVM_STABLE}" # Default to the current stable branch
ALL='0'
HTTP_CLIENT='none'
CODENAME=''
CODENAME_FROM_ARGUMENTS='0'


# --- Function Group ---

stdout() { printf -- '%s\n' "${@}" ; }
stderr() { stdout "${@}" ; } 1>&2

info()  { stdout "[info] ${*}"; }
warn()  { stderr "[warn] ${*}"; }

# error_exit [EXIT_CODE] [MESSAGE...]
# Never returns 0
error_exit() {
    local previous_exit_code="${?}"
    local code="${previous_exit_code}"
    if (( '0' < "${#}" )); then
        printf -v 'code' -- '%d' "${1}" 2>/dev/null && \
            shift || code="${previous_exit_code}"
    fi
    local line ; for line in "${@}"; do
        stderr "[error] ${line}"
    done
    if (( '0' == "${code}" )); then
        code='1'
    fi
    exit "${code}"
}

usage() {
    set +x
    stderr "Usage: ${0} [llvm_major_version] [all] [latest] [OPTIONS]" \
        '' \
        'Arguments:' \
        '  llvm_major_version'$'\t''The major version to install (e.g. 20)' \
        '  all'$'\t\t\t''Install all packages.' \
        '  latest'$'\t\t''Use the latest LLVM version ('"${LATEST_LLVM_VERSION}"').' \
        '' \
        'Options:' \
        '  -n, --code-name <name>'$'\t''Specifies the distro codename (e.g. noble)' \
        '  -m, --mirror <url>'$'\t''Specifies the base URL for download.' \
        '  -h, --help'$'\t\t''Prints this help.'
    exit "${#}"
}

setup_llvm_version_patterns() {
    # The latest version uses the base repository name (no suffix)
    LLVM_VERSION_PATTERNS["${LATEST_LLVM_VERSION}"]=''

    local _v
    for (( _v='9'; "${LATEST_LLVM_VERSION}" > "${_v}"; _v++ )); do
        LLVM_VERSION_PATTERNS["${_v}"]="-${_v}"
    done
}

parse_flag_value() {
    if [[ -z "${2-}" ]]; then
        warn "Option ${1} requires an argument."
        usage error
    fi
}

parse_args() {
    local _flag
    while (( '0' < "${#}" )); do
        case "${1}" in
            (--) break ;;
            (-h|--help)
                usage
                ;;
            (-m=*|--mirror=*)
                BASE_URL="${1#*=}"
                shift
                ;;
            (-m|--mirror)
                _flag="${1}"
                shift
                parse_flag_value "${_flag}" "${1-}"
                BASE_URL="${1}"
                shift
                ;;
            (-n=*|--code-name=*)
                CODENAME="${1#*=}"
                CODENAME_FROM_ARGUMENTS='1'
                shift
                ;;
            (-n|--code-name)
                _flag="${1}"
                shift
                parse_flag_value "${_flag}" "${1-}"
                CODENAME="${1}"
                shift
                CODENAME_FROM_ARGUMENTS='1'
                ;;
            (all)
                shift
                ALL='1'
                ;;
            (latest)
                shift
                LLVM_VERSION="${LATEST_LLVM_VERSION}"
                ;;
            (*)
                case "${1}" in
                    (-*)
                        warn "Unknown or unsupported flag: ${1}"
                        usage error
                        ;;
                    ([9123]*)
                        if [[ -z "${LLVM_VERSION_PATTERNS[${1}]+set}" ]]; then
                            error_exit '3' "This script does not support LLVM version ${1}"
                        fi

                        LLVM_VERSION="${1}"
                        shift
                        ;;
                    (*)
                        error_exit '1' "Unrecognized argument: ${1}"
                        ;;
                esac
                ;;
        esac
    done

    # Lock strictly finalized variables
    readonly BASE_URL
    readonly LLVM_VERSION
    readonly ALL

    # Only lock this if it was actually set to true;
    # otherwise, detection logic might need to toggle it or rely on its mutability.
    case "${CODENAME_FROM_ARGUMENTS}" in
        (1)
            readonly CODENAME
            readonly CODENAME_FROM_ARGUMENTS
            ;;
    esac
}

download_key() {
    local url="${1}"
    case "${HTTP_CLIENT}" in
        (busybox) busybox "${BUSYBOX_WGET_COMMON[@]}" "${url}" ;;
        (curl) curl "${CURL_FINAL[@]}" "${url}" ;;
        (wget) wget "${WGET_COMMON[@]}" --output-document - "${url}" ;;
    esac
}

check_url() {
    local url="${1}"
    case "${HTTP_CLIENT}" in
        (busybox) busybox "${BUSYBOX_WGET_COMMON[@]}" "${url}" >/dev/null 2>&1 ;;
        (curl) curl "${CURL_FINAL[@]}" --head "${url}" >/dev/null 2>&1 ;;
        (wget) wget "${WGET_COMMON[@]}" --method=HEAD "${url}" >/dev/null 2>&1 ;;
    esac
}

detect_http_client() {
    # Priority: curl -> wget -> busybox
    if builtin command -v curl >/dev/null 2>&1; then
        HTTP_CLIENT='curl'
        # Check for retry-all-errors support (modern curl only)
        if curl --help all 2>/dev/null | grep -Fe 'retry-all-errors' >/dev/null 2>&1; then
            CURL_FINAL+=('--retry-all-errors')
        fi
    elif builtin command -v wget >/dev/null 2>&1; then
        HTTP_CLIENT='wget'
    elif builtin command -v busybox >/dev/null && busybox wget --help >/dev/null 2>&1; then
        HTTP_CLIENT='busybox'
    else
        error_exit '4' 'Neither curl nor wget found. Install one and retry.'
    fi
}

identify_debian_generation() {
    local _name _version _major
    is_old_debian='0'

    # Determine Distro Name
    _name="$(
        lsb_release -si 2>/dev/null || \
            { . /etc/os-release && echo "${NAME%% *}"; }
        )"

    if [[ 'debian' != "${_name,,}" ]]; then
        return 0
    fi

    # Determine Major Version
    _version="$(
        lsb_release -sr 2>/dev/null || \
            { . /etc/os-release && echo "${VERSION_ID}"; }
        )"
    # Debian doesn't require this, but we are keeping it as defensive.
    _major="${_version%%.*}"

    # Logic: Numeric and less than 12 (Bookworm) is 'old'
    if [[ "${_major}" =~ ^[0-9]+$ ]] && (( '12' > "${_major}" )); then
        is_old_debian='1'
    fi
}

remove_old_key() {
    # Fast failure: exit if apt-key is missing or LLVM isn't in the keyring
    builtin command -v apt-key >/dev/null || return 1
    apt-key list 2>/dev/null | grep -Fie 'llvm' >/dev/null || return 2

    # Full Fingerprint for LLVM Snapshot Archive Key (2015-2025)
    apt-key del "6084F3CF814B57C1CF12EFD515CF4D18AF4F7421"
}

add_pkgs() {
    if [[ "$(declare -p PKGS 2>/dev/null)" != "declare -A PKGS"* ]]; then
        warn "PKGS associative array must be declared before calling add_pkgs."
        return 1
    fi

    local suffix
    suffix="${1}"
    shift
    # suffix can be empty or already begin with `-`
    if [[ -n "${suffix}" && "${suffix}" != -* ]]; then
        suffix="-${suffix}"
    fi

    local name
    for name in "${@}"; do
        PKGS+=(["${name}${LLVM_VERSION_PATTERNS[${LLVM_VERSION}]}${suffix}"]=1)
    done
}


# --- Execution Start ---

# Parse Arguments (Encapsulated, non-destructive to global scope)
parse_args "${@}"

# Binary Verification
declare -a missing_binaries=()
for _binary in "${NEEDED_BINARIES[@]}"; do
    if ! builtin command -v "${_binary}" >/dev/null 2>&1; then
        missing_binaries+=("${_binary}")
    fi
done
unset -v _binary

# HTTP Client Decision (Prioritizing curl)
declare -a CURL_FINAL=("${CURL_COMMON[@]}")
detect_http_client
readonly CURL_FINAL HTTP_CLIENT

# --- Distro Identification ---

is_old_debian='0'
identify_debian_generation
readonly is_old_debian

if (( '0' < "${#missing_binaries[@]}" )); then
    # If it's old Debian, everything in the list is a hard requirement.
    # If it's new, we only error if there's more than one missing OR the one missing isn't the repository tool.
    ## if (( '1' == "${is_old_debian}" )) || (( '1' < "${#missing_binaries[@]}" )) || [[ 'add-apt-repository' != "${missing_binaries[0]}" ]]; then
    # add-apt-repository is not needed for newer Debian distros
    if (( '1' == "${is_old_debian}" )) || [[ 'add-apt-repository' != "${missing_binaries[*]}" ]]; then
        case "${HTTP_CLIENT}" in
            (busybox|none) missing_binaries+=('curl') ;;
        esac
        declare -a _hint_pkgs=()
        for _bin in "${missing_binaries[@]}"; do
            case "${_bin}" in
                (lsb_release)            _hint_pkgs+=('lsb-release') ;;
                (gpg)                    _hint_pkgs+=('gnupg') ;;
                (add-apt-repository)     _hint_pkgs+=('software-properties-common') ;;
                (*)                      _hint_pkgs+=("${_bin}") ;;
            esac
        done
        unset -v _bin

        error_exit '4' "Missing required tools: ${missing_binaries[*]}" \
            "(hint: apt install ${_hint_pkgs[*]})" \
            "wget is also supported as an alternative to curl"
    fi
fi

DISTRO="$(lsb_release -is)"
VERSION_CODENAME="$(lsb_release -cs)"
VERSION="$(lsb_release -sr)"
UBUNTU_CODENAME=""


# Obtain VERSION_CODENAME and UBUNTU_CODENAME (for Ubuntu and its derivatives)
source /etc/os-release
DISTRO="${DISTRO,,}"

case "${DISTRO}" in
    debian)
        # Debian Forky has a workaround because of
        # https://bugs.debian.org/cgi-bin/bugreport.cgi?bug=1038383
        if [[ "${VERSION}" == "unstable" ]] || [[ "${VERSION}" == "testing" ]] || [[ "${VERSION_CODENAME}" == "forky" ]]; then
            CODENAME=unstable
            LINKNAME=
        else
            # "stable" Debian release
            CODENAME="${VERSION_CODENAME}"
            LINKNAME="-${CODENAME}"
        fi
        ;;
    *)
        # ubuntu and its derivatives
        if [[ -n "${UBUNTU_CODENAME}" ]]; then
            CODENAME="${UBUNTU_CODENAME}"
            if [[ -n "${CODENAME}" ]]; then
                LINKNAME="-${CODENAME}"
            fi
        fi
        ;;
esac


# double-check both the default and argument value
if [[ -z "${LLVM_VERSION_PATTERNS[${LLVM_VERSION}]+set}" ]]; then
    error_exit '3' "This script does not support LLVM version ${LLVM_VERSION}"
fi

declare -A PKGS
add_pkgs '' clang{,d} lld{,b}
if (( '1' == "${ALL}" )); then
    # packages without any suffix
    add_pkgs '' clang-{format,tidy,tools}
    # -dev suffixed packages
    add_pkgs 'dev' lib{c++{,abi},clang{,-{common,cpp}},lldb,omp,unwind} 'llvm'

    add_pkgs 'tools' llvm
    if (( '14' < "${LLVM_VERSION}" )); then
        add_pkgs 'dev' 'libclang-rt' 'libpolly'
    fi
fi

# join the repository name
if [[ -n "${CODENAME}" ]]; then
    REPO_NAME="deb ${BASE_URL}/${CODENAME}/ llvm-toolchain${LINKNAME}${LLVM_VERSION_STRING} main"
    # check if the repository exists for the distro and version
    if ! check_url "${BASE_URL}/${CODENAME,,}"; then
        if (( '1' == "${CODENAME_FROM_ARGUMENTS}" )); then
            error_exit 2 "Specified codename '${CODENAME}' is not supported by this script."
        else
            error_exit 2 "Distribution '${DISTRO}' in version '${VERSION}' is not supported by this script."
        fi
    fi
fi

# Root Check (Fail-fast after validation)
if (( '0' != "${EUID}" )); then
    error_exit '1' 'This script must be run as root!'
fi

# install everything
if ! [[ -f "${GPG_KEY_PATH}" ]]; then
    if ! check_url "${GPG_KEY_URL}"; then
        error_exit '2' "GPG key not reachable at ${GPG_KEY_URL}"
    fi
    download_key "${GPG_KEY_URL}" | tee "${GPG_KEY_PATH}"
fi

# Add repository based on distribution
if [[ "debian" == "${DISTRO,,}" ]] && (( '0' == "${is_old_debian}" )); then
    # On Debian:
    #  - Bookworm (12) has a buggy `add-apt-repository` tool
    #  - Trixie (13) and later may not even have that tool
    # As a consequence, we will write the DEB822 format directly below.
    SOURCES_FILE="/etc/apt/sources.list.d/http_apt_llvm_org_${CODENAME}_-${VERSION_CODENAME}.sources"
    tee -a "${SOURCES_FILE}" >/dev/null <<EOF
Types: deb
Architectures: amd64 arm64
Signed-By: ${GPG_KEY_PATH}
URIs: ${BASE_URL}/${CODENAME,,}/
Suites: llvm-toolchain${LINKNAME}${LLVM_VERSION_PATTERNS[${LLVM_VERSION}]}
Components: main

EOF
else
    add-apt-repository -y "${REPO_NAME}"
fi

if remove_old_key; then
    info 'The old LLVM signing key has been removed.'
fi

apt-get update
apt-get install -y "${!PKGS[@]}"
