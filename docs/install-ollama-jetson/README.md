# install-ollama-jetson

`install-ollama-jetson.sh` installs Ollama on an NVIDIA Jetson device and configures it as a system service so the integrated GPU can be used when the CUDA backend is present.

The script is intended for ARM64 Jetson systems running a Linux distribution compatible with the upstream Ollama install script, and it is specifically designed to set up Ollama as a persistent service rather than a one-off local install.

> **Warning**
>
> The script makes system-level changes by installing packages, writing service configuration under `/etc/systemd/system/`, and enabling the `ollama` service. Review the script before running it on a production system.

## Supported Environment

- NVIDIA Jetson platform
- ARM64 architecture (`aarch64`)
- Bash
- `curl`
- `sudo`
- `systemctl`
- Network access to download Ollama installation assets

This script is intended for Jetsons running JetPack 7.2+. This guide was tested on a Jetson Orin Nano running JetPack 7.2 in July 2026.

## What the script does

1. Verifies that the current machine is ARM64.
2. Downloads and runs the upstream Ollama installer.
3. Sets up Ollama as a system service through the standard service management flow.
4. Looks for the CUDA backend library under the Ollama installation directories.
5. Writes a systemd override file so the `ollama` service can discover and use the integrated GPU.
6. Reloads systemd, enables the `ollama` service, and restarts it.
7. Prints the service status and a couple of suggested follow-up commands.

## Installation

Clone the repository and make the script executable:

```bash
git clone <repository-url>
cd <repository-directory>
chmod +x tools/install-ollama-jetson.sh
```

## Usage

Run the script from the repository root:

```bash
./tools/install-ollama-jetson.sh
```

The script uses `sudo` for service configuration changes.

## Expected Result

After a successful run, Ollama should be installed and the `ollama` systemd service should be enabled and running as a background service. You can verify it with:

```bash
systemctl status ollama
ollama ps
```

## Next Steps

Try a local model with:

```bash
ollama run llama3.2:1b
```

You can also list currently running models with:

```bash
ollama ps
```

## Notes

- The script expects the CUDA backend to be installed in the standard Ollama library directories.
- If the backend is not found, the script still enables integrated GPU discovery, but the full CUDA-enabled runtime configuration may not be available.
- If the installer changes upstream, you may need to update this script to match the latest package or service conventions.
