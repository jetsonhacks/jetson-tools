#!/usr/bin/env bash

set -euo pipefail

ARCH="$(uname -m)"
TMP_DIR=""

cleanup() {
    if [[ -n "${TMP_DIR}" && -d "${TMP_DIR}" ]]; then
        rm -rf "${TMP_DIR}"
    fi
}
trap cleanup EXIT

echo "Architecture: ${ARCH}"

if [[ "${ARCH}" != "aarch64" ]]; then
    echo "This installer is intended for ARM64 Jetson systems." >&2
    exit 1
fi

for cmd in curl sudo systemctl find tee dirname uname; do
    if ! command -v "${cmd}" >/dev/null 2>&1; then
        echo "Required command not found: ${cmd}" >&2
        exit 1
    fi
done

if [[ $(id -u) -ne 0 ]]; then
    if ! sudo -n true >/dev/null 2>&1; then
        echo "This installer needs sudo privileges to configure the Ollama service." >&2
        exit 1
    fi
fi

echo "Installing Ollama as a system service..."
TMP_DIR="$(mktemp -d)"
INSTALLER_SCRIPT="${TMP_DIR}/install-ollama.sh"

curl -fsSL https://ollama.com/install.sh -o "${INSTALLER_SCRIPT}"
sh "${INSTALLER_SCRIPT}"

CUDA_BACKEND="$(
    find /usr/local/lib/ollama /usr/lib/ollama \
        -path '*/cuda_v*/libggml-cuda.so' \
        -type f -print -quit 2>/dev/null || true
)"

sudo install -d /etc/systemd/system/ollama.service.d

if [[ -n "${CUDA_BACKEND}" ]]; then
    CUDA_DIR="$(dirname "${CUDA_BACKEND}")"
    OLLAMA_LIB_DIR="$(dirname "${CUDA_DIR}")"

    echo "Found CUDA backend: ${CUDA_BACKEND}"

    sudo tee /etc/systemd/system/ollama.service.d/jetson.conf >/dev/null <<EOF
[Service]
Environment="OLLAMA_IGPU_ENABLE=1"
Environment="GGML_BACKEND_PATH=${CUDA_BACKEND}"
Environment="LD_LIBRARY_PATH=${OLLAMA_LIB_DIR}:${CUDA_DIR}"
EOF
else
    echo >&2
    echo "WARNING: No CUDA backend (libggml-cuda.so) found under /usr/local/lib/ollama or /usr/lib/ollama." >&2
    echo "         Ollama will run without GPU acceleration configured. Enabling integrated GPU discovery only." >&2
    echo >&2

    sudo tee /etc/systemd/system/ollama.service.d/jetson.conf >/dev/null <<'EOF'
[Service]
Environment="OLLAMA_IGPU_ENABLE=1"
EOF
fi

sudo systemctl daemon-reload

if ! sudo systemctl enable --now ollama; then
    echo "Failed to enable the ollama service. Review the upstream installation output." >&2
    exit 1
fi

sudo systemctl restart ollama

echo
echo "Ollama service status:"
systemctl --no-pager --full status ollama || true

echo
echo "Next:"
echo "  ollama run llama3.2:1b"
echo "  ollama ps"
