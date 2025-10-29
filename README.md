# Alpine Linux Chroot Installer

This script installs Alpine Linux into a chroot environment and optionally sets up qemu-user and binfmt for emulating different architectures (e.g., armhf).

## System Compatibility

The script supports automatic dependency installation on:
- **Debian-based systems**: Automatic installation using apt-get
- **ArchLinux**: Automatic installation using pacman
- **Other Linux systems**: Basic functionality (manual dependency installation required)

## Overview

The script creates a complete Alpine Linux chroot environment with the following features:

1. **Multi-architecture support**: Can emulate different CPU architectures using QEMU
2. **Automatic dependency management**: Installs required packages based on your system
3. **Helper scripts**: Creates convenient entry and cleanup scripts
4. **Filesystem binding**: Mounts necessary system directories

### Generated Scripts

The installer creates two helper scripts in the chroot directory:

#### enter-chroot
This script provides easy access to the chroot environment and:
1. Saves environment variables specified by `$CHROOT_KEEP_VARS` and current directory
2. Performs chroot into the target directory
3. Starts a clean environment using `env -i`
4. Switches user and simulates full login using `su -l`
5. Loads saved environment variables and changes to saved directory
6. Executes specified command or starts a shell

#### destroy
This script safely unmounts all filesystems and optionally removes the chroot directory.

## Prerequisites

**Important**: This script must be run as root.

### Debian Systems
```bash
apt update
# Dependencies are installed automatically if needed
```

### ArchLinux
```bash
pacman -Sy
# Dependencies are installed automatically if needed
```

### Other Systems
Install manually:
- `curl` or `wget` for downloads
- `qemu-user-static` (for architecture emulation)
- `binfmt-support` or equivalent (for architecture emulation)

## Installation

```bash
# Download the script
curl -fsSL https://raw.githubusercontent.com/fquinto/alpinelinux/main/alpine-rootfs-setup.sh -o alpine-rootfs-setup.sh
chmod +x alpine-rootfs-setup.sh
```

## Quick Start

```bash
# One-line installation and setup
curl -fsSL https://raw.githubusercontent.com/fquinto/alpinelinux/main/alpine-rootfs-setup.sh | sudo sh
```

## Usage

### Basic Installation
```bash
./alpine-rootfs-setup.sh
```

### Custom Installation
```bash
./alpine-rootfs-setup.sh -d /opt/my-alpine -p build-base -p cmake
```

### Cross-Architecture Installation
```bash
./alpine-rootfs-setup.sh -a armhf -d /opt/alpine-arm
```

### Working with the Chroot

#### Enter as root
```bash
/opt/alpine-rootfs/enter-chroot
```

#### Enter as specific user
```bash
/opt/alpine-rootfs/enter-chroot -u username
```

#### Execute commands directly
```bash
/opt/alpine-rootfs/enter-chroot -u $USER ./build-script.sh
```

### Cleanup

#### Unmount filesystems only
```bash
/opt/alpine-rootfs/destroy
```

#### Complete removal
```bash
/opt/alpine-rootfs/destroy --remove
```

## Command Line Options

| Option | Environment Variable | Description | Default |
|--------|---------------------|-------------|---------|
| `-a ARCH` | `ARCH` | CPU architecture for the chroot. If different from host, will be emulated using qemu-user. Options: x86_64, x86, aarch64, armhf, armv7, loongarch64, ppc64le, riscv64, s390x | Host architecture |
| `-b ALPINE_BRANCH` | `ALPINE_BRANCH` | Alpine branch to install | `latest-stable` |
| `-d CHROOT_DIR` | `CHROOT_DIR` | Absolute path to chroot installation directory | `/opt/alpine-rootfs` |
| `-i BIND_DIR` | `BIND_DIR` | Host directory to mount inside chroot at same path | PWD if under /home, otherwise none |
| `-k CHROOT_KEEP_VARS` | `CHROOT_KEEP_VARS` | Environment variable names to pass to chroot (supports regex) | `ARCH CI QEMU_EMULATOR TRAVIS_.*` |
| `-m ALPINE_MIRROR` | `ALPINE_MIRROR` | Alpine mirror URI for package downloads | `https://dl-cdn.alpinelinux.org/alpine` |
| `-p ALPINE_PACKAGES` | `ALPINE_PACKAGES` | Alpine packages to install in chroot | `build-base ca-certificates ssl_client` |
| `-r EXTRA_REPOS` | `EXTRA_REPOS` | Additional Alpine repositories to add | None |
| `-t TEMP_DIR` | `TEMP_DIR` | Temporary files directory | `mktemp -d` |
| `-n` | `SKIP_VERSION_CHECK` | Skip automatic version update check | `no` |
| `-h` | - | Show help and exit | - |
| `-v` | - | Show version and exit | - |

### Additional Environment Variables

| Variable | Description |
|----------|-------------|
| `APK_TOOLS_URI` | Custom URL for apk.static download. If unset, latest version is fetched automatically |
| `APK_TOOLS_SHA256` | SHA-256 checksum for custom APK_TOOLS_URI (optional) |

**Note**: Each option can also be provided via environment variable. Command line options take precedence over environment variables.

## Supported Architectures

- **x86_64**: Intel/AMD 64-bit
- **x86**: Intel/AMD 32-bit  
- **aarch64**: ARM 64-bit
- **armhf**: ARM hard-float
- **armv7**: ARM version 7
- **loongarch64**: LoongArch 64-bit
- **ppc64le**: PowerPC 64-bit little-endian
- **riscv64**: RISC-V 64-bit
- **s390x**: IBM System/390 64-bit

## Important Notes

### Security Considerations
- The script must run as root for chroot creation and filesystem mounting
- Default PWD binding behavior exists for legacy compatibility but can be security-sensitive
- Always review the directories being bound into the chroot

### Architecture Emulation
- Cross-architecture support requires QEMU user-mode emulation
- QEMU binaries are automatically installed on supported systems
- Some performance impact is expected when using emulation
- The ash shell in Alpine may not load login profiles correctly under QEMU emulation, which is why `/etc/profile` is explicitly sourced

### System-Specific Notes

#### ArchLinux
- Uses `qemu-arch-extra` or `qemu-user-static-bin` from AUR
- binfmt_misc support is usually built into the kernel
- Manual package installation may be required: `pacman -S qemu-arch-extra`

#### Debian
- Uses standard repository packages: `qemu-user-static` and `binfmt-support`
- Automatic package cache updates

## Troubleshooting

### Error: \"binfmt_misc not available\"
On ArchLinux, ensure your kernel has binfmt_misc support:
```bash
zcat /proc/config.gz | grep CONFIG_BINFMT_MISC
```

### Error: \"qemu-user-static not found\"
Try manual installation:

**ArchLinux:**
```bash
# Option 1: AUR package
yay -S qemu-user-static-bin

# Option 2: Official package
pacman -S qemu-arch-extra
```

**Debian:**
```bash
apt-get update && apt-get install qemu-user-static
```

### Permission Issues
Ensure you're running as root:
```bash
# Check current user
id

# If not root, use su or sudo to become root
su -
# or if you have sudo access
sudo -i
```

### Mount Issues
If you encounter filesystem mount problems:
```bash
# Check existing mounts
mount | grep alpine

# Manual cleanup if needed
umount -R /opt/alpine-rootfs
```

## Examples

### Development Environment
```bash
# Create Alpine chroot with development tools
./alpine-rootfs-setup.sh -p \"build-base git cmake ninja\"

# Enter and start working
/opt/alpine-rootfs/enter-chroot -u $USER
```

### Cross-Compilation Setup
```bash
# ARM development environment
./alpine-rootfs-setup.sh -a armhf -d /opt/alpine-arm -p \"build-base gcc-arm-none-eabi\"

# Enter ARM environment
/opt/alpine-arm/enter-chroot
```

### CI/CD Integration
```bash
# Minimal Alpine for testing
./alpine-rootfs-setup.sh -p \"busybox curl\"

# Run tests in clean environment
/opt/alpine-rootfs/enter-chroot ./run-tests.sh
```

## Common Use Cases

### Docker Alternative
Use Alpine chroot as a lightweight container alternative:
```bash
./alpine-rootfs-setup.sh -p "nginx php8"
/opt/alpine-rootfs/enter-chroot nginx
```

## Contributing

Contributions are welcome! Please:

1. Fork the repository
2. Create a feature branch (`git checkout -b feature/my-feature`)
3. Commit your changes (`git commit -am 'Add my feature'`)
4. Push to the branch (`git push origin feature/my-feature`)
5. Create a Pull Request

## License

See [LICENSE](LICENSE) file for details.

## Status

[![License](https://img.shields.io/github/license/fquinto/alpinelinux)](LICENSE)
[![Latest Release](https://img.shields.io/github/v/release/fquinto/alpinelinux)](https://github.com/fquinto/alpinelinux/releases)
[![Issues](https://img.shields.io/github/issues/fquinto/alpinelinux)](https://github.com/fquinto/alpinelinux/issues)
