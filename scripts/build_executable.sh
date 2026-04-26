#!/bin/bash
set -euo pipefail

system=${1:-}
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
ROOT_DIR=$(cd "${SCRIPT_DIR}/.." && pwd)
SPEC_DIR="${ROOT_DIR}/packaging/pyinstaller/specs"
DIST_DIR="${ROOT_DIR}/dist"
export X_ANYLABELING_ROOT="${ROOT_DIR}"

usage() {
    cat <<EOF
Usage: $(basename "$0") {win-cpu|win-gpu|linux-cpu|linux-gpu|macos}

Build X-AnyLabeling executable artifacts with PyInstaller.
Aliases: linux-gp -> linux-gpu, win-gp -> win-gpu
EOF
}

fail() {
    echo "Error: $*" >&2
    exit 1
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || fail "Required command '$1' was not found."
}

require_file() {
    [ -f "$1" ] || fail "Required file '$1' was not found."
}

# Prefer `python -m PyInstaller` so Conda/venv on Windows (Git Bash) does not
# need `pyinstaller` on PATH (Scripts/ is often missing from bash).
resolve_build_python() {
    if [ -n "${PYTHON:-}" ]; then
        if command -v "${PYTHON}" >/dev/null 2>&1; then
            command -v "${PYTHON}"
        elif [ -x "${PYTHON}" ]; then
            echo "${PYTHON}"
        else
            fail "PYTHON is set to '${PYTHON}' but is not a valid interpreter."
        fi
    elif command -v python3 >/dev/null 2>&1; then
        command -v python3
    elif command -v python >/dev/null 2>&1; then
        command -v python
    else
        fail "No python in PATH. Activate your conda/venv, or set PYTHON to the full path to python.exe (e.g. in Git Bash: export PYTHON=\"\$CONDA_PREFIX/python.exe\")."
    fi
}

require_pyinstaller_module() {
    local py
    py=$1
    "${py}" -c "import PyInstaller" 2>/dev/null \
        || fail "PyInstaller is not installed for: ${py}. Run: ${py} -m pip install pyinstaller"
}

build_with_spec() {
    local label device spec_path py

    label=$1
    device=$2
    spec_path=$3

    py=$(resolve_build_python)
    require_pyinstaller_module "${py}"
    require_file "${spec_path}"

    echo "Building ${label} version (using: ${py} -m PyInstaller)..."
    export X_ANYLABELING_DEVICE="${device}"
    "${py}" -m PyInstaller --noconfirm "${spec_path}"
}

package_macos_release_zip() {
    local apps app_path latest_app app_name exe_name exe_path arch_info arch zip_name zip_path sha_path

    apps=("${DIST_DIR}"/X-AnyLabeling-v*-macOS.app)
    if [ ! -e "${apps[0]}" ]; then
        fail "No macOS .app bundle found in ${DIST_DIR}."
    fi

    latest_app=${apps[0]}
    for app_path in "${apps[@]}"; do
        if [ "${app_path}" -nt "${latest_app}" ]; then
            latest_app=${app_path}
        fi
    done

    app_path=${latest_app}
    app_name=$(basename "${app_path}" .app)

    require_command ditto
    require_command file
    require_command shasum
    [ -x /usr/libexec/PlistBuddy ] || fail "Required command '/usr/libexec/PlistBuddy' was not found."

    exe_name=$(/usr/libexec/PlistBuddy -c "Print :CFBundleExecutable" "${app_path}/Contents/Info.plist" 2>/dev/null || true)
    exe_path="${app_path}/Contents/MacOS/${exe_name}"
    if [ -z "${exe_name}" ] || [ ! -f "${exe_path}" ]; then
        fail "Failed to locate app executable in ${app_path}."
    fi

    arch_info=$(lipo -info "${exe_path}" 2>/dev/null || file "${exe_path}")
    if [[ "${arch_info}" == *"arm64"* && "${arch_info}" == *"x86_64"* ]]; then
        arch="universal2"
    elif [[ "${arch_info}" == *"arm64"* ]]; then
        arch="arm64"
    elif [[ "${arch_info}" == *"x86_64"* ]]; then
        arch="x86_64"
    else
        arch=$(uname -m)
    fi

    zip_name="${app_name}-${arch}-unsigned.zip"
    zip_path="${DIST_DIR}/${zip_name}"
    sha_path="${zip_path}.sha256"

    echo "Packaging macOS release artifact..."
    rm -f "${zip_path}" "${sha_path}"
    ditto -c -k --norsrc --keepParent "${app_path}" "${zip_path}"

    (
        cd "${DIST_DIR}"
        shasum -a 256 "${zip_name}" > "${zip_name}.sha256"
    )

    echo "Created release zip: ${zip_path}"
    echo "Created checksum: ${sha_path}"
}

# Accept common shorthands (e.g. linux-gp / win-gp -> *-gpu)
case "${system}" in
    linux-gp) system=linux-gpu ;;
    win-gp) system=win-gpu ;;
esac

case "${system}" in
    win-cpu)
        build_with_spec "Windows CPU" "CPU" "${SPEC_DIR}/x-anylabeling-win-cpu.spec"
        ;;
    win-gpu)
        build_with_spec "Windows GPU" "GPU" "${SPEC_DIR}/x-anylabeling-win-gpu.spec"
        ;;
    linux-cpu)
        build_with_spec "Linux CPU" "CPU" "${SPEC_DIR}/x-anylabeling-linux-cpu.spec"
        ;;
    linux-gpu)
        build_with_spec "Linux GPU" "GPU" "${SPEC_DIR}/x-anylabeling-linux-gpu.spec"
        ;;
    macos)
        build_with_spec "macOS" "CPU" "${SPEC_DIR}/x-anylabeling-macos.spec"
        package_macos_release_zip
        ;;
    -h|--help|help)
        usage
        ;;
    "")
        usage
        fail "Missing system value."
        ;;
    *)
        usage
        fail "System value '${system}' is not recognized."
        ;;
esac
