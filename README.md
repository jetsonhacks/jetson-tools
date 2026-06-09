# jetson-tools

A collection of command-line tools and supporting documentation for working with NVIDIA Jetson systems.

The repository contains practical utilities developed for Jetson setup, installation, diagnostics, and system maintenance. Each tool is documented separately so that the repository can grow without turning this README into a complete manual for every utility.

## Tools

| Tool                                                                 | Description                                                                                                                                                   |
| -------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| [`write-verify-usb-image.sh`](docs/write-verify-usb-image/README.md) | Writes a raw disk image to a USB drive and verifies the result byte-for-byte. Intended for creating JetPack installation media directly from a Jetson system. |

## Repository Layout

```text
.
├── README.md
├── tools/
│   └── write-verify-usb-image.sh
└── docs/
    └── write-verify-usb-image/
        ├── README.md
        └── DESIGN.md
```

* `tools/` contains executable scripts and utilities.
* `docs/` contains user guides, design notes, and other supporting documentation for each tool.

## Platform

The tools in this repository are intended primarily for NVIDIA Jetson systems.

Platform and software requirements may differ by tool. Refer to the individual tool documentation before use.

## Usage

Clone the repository:

```bash
git clone <repository-url>
cd <repository-name>
```

Tools can then be run from the `tools/` directory. Some tools perform privileged or destructive operations and may use `sudo`.

Read the documentation for a tool before running it.

## Documentation

Each tool has its own documentation directory under `docs/`.

User-facing instructions are provided in the tool's `README.md`. Additional files such as `DESIGN.md` describe implementation decisions, safety constraints, and known limitations.

## License

See the repository license for usage and redistribution terms.
