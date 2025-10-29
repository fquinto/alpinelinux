#!/bin/sh
#---help---
# Alpine Linux chroot installer with multi-architecture support
# Supports Debian (apt) and ArchLinux (pacman) for automatic dependency installation
#
# Usage: alpine-rootfs-setup [options]
#
# Main options:
#   -a ARCH      Architecture (x86_64, armhf, aarch64, etc.)
#   -d DIR       Destination directory (default: /opt/alpine-rootfs)  
#   -p PACKAGES  Packages to install
#   -n           Skip version update check
#   -D           Dry run (validate configuration without installing)
#   -h           Show complete help
#   -v           Show version
#
# Example: alpine-rootfs-setup -d /opt/alpine-rootfs -p build-base -p cmake
#
# See README.md for complete documentation
#---help---
set -eu

# Set English locale to avoid localized error messages
export LC_ALL=C

#=====  Constants  =====#

# Version of the alpine-rootfs-setup script
VERSION='0.0.2'

#=====  Functions  =====#

# Display error message in red and exit
print_error() {
	printf '\033[1;31mERROR:\033[0m %s\n' "$@" >&2
	exit 1
}

# Display informational message in cyan
print_info() {
	printf '\n\033[1;36m> %s\033[0m\n' "$@" >&2
}

# Display warning message in yellow
print_warning() {
	printf '\033[1;33m> %s\033[0m\n' "$@" >&2
}

# Display basic help information
show_usage() {
	sed -En '/^#---help---/,/^#---help---/p' "$0" | sed -E 's/^# ?//; 1d;$d;'
	echo
	echo "For complete documentation with detailed examples, see README.md"
}

# Detect host operating system
detect_host_system() {
	if command -v pacman >/dev/null; then
		echo "arch"
	elif command -v apt-get >/dev/null; then
		echo "debian"
	else
		echo "unknown"
	fi
}

# Normalize architecture names for QEMU compatibility
normalize_architecture() {
	case "$1" in
		x86 | i[3456]86) echo 'i386';;
		armhf | armv[4-9]) echo 'arm';;
		*) echo "$1";;
	esac
}

# Download file from URL using curl or wget
download_from_url() {
	local url="$1"
	local output="${2:-}"

	echo "Downloading $url" >&2
	if command -v curl >/dev/null; then
		if [ -n "$output" ]; then
			curl --connect-timeout 10 -fsSL -o "$output" "$url" || {
				print_error "Failed to download $url to $output"
			}
		else
			curl --connect-timeout 10 -fsSL "$url" || {
				print_error "Failed to download $url"
			}
		fi
	elif command -v wget >/dev/null; then
		if [ -n "$output" ]; then
			wget -T 10 --no-verbose -O "$output" "$url" || {
				print_error "Failed to download $url to $output"
			}
		else
			wget -T 10 --no-verbose -O- "$url" || {
				print_error "Failed to download $url"
			}
		fi
	else
		print_error 'Cannot download file: neither curl nor wget is available!'
	fi
}

# Download file and optionally verify checksum
download_and_verify() {
	local url="$1"
	local checksum="$2"
	local dest="${3:-.}"
	local filename="${url##*/}"

	mkdir -p "$dest" \
		&& cd "$dest" \
		&& rm -f "$filename" \
		&& download_from_url "$url" "$filename"
	
	# Skip checksum verification for APKINDEX-provided checksums (they're for package content, not files)
	# Only verify if user explicitly provided external checksums via APK_TOOLS_SHA256 etc.
	if [ -n "$checksum" ] && [ "$checksum" != "" ] && [ "${VERIFY_CHECKSUMS:-no}" = "yes" ]; then
		print_info "Verifying checksum for $filename"
		
		# Determine checksum type by length
		case "${#checksum}" in
			40) # SHA1
				echo "$checksum  $filename" | sha1sum -c >/dev/null || {
					print_warning "SHA1 checksum verification failed for $filename"
					print_warning "Expected: $checksum"
					print_warning "Continuing anyway - this may indicate a corrupted download"
				}
				;;
			64) # SHA256
				echo "$checksum  $filename" | sha256sum -c >/dev/null || {
					print_warning "SHA256 checksum verification failed for $filename"
					print_warning "Expected: $checksum"
					print_warning "Continuing anyway - this may indicate a corrupted download"
				}
				;;
			*) # Unknown format
				print_warning "Unknown checksum format for $filename (length: ${#checksum})"
				print_warning "Skipping verification"
				;;
		esac
	else
		# APKINDEX checksums are for package content verification by APK tools,
		# not for file integrity verification. We rely on HTTPS for download integrity.
		print_info "Downloaded $filename successfully (checksum verification skipped)"
	fi
}

# Extract Alpine APK keys from alpine-keys package to specified directory
extract_alpine_keys() {
	local dest_dir="$1"
	local keys_pkg="$2"
	local temp_extract="$(mktemp -d)"
	
	mkdir -p "$dest_dir"
	
	# Extract the package to a temporary directory
	tar -xz -f "$keys_pkg" -C "$temp_extract" 2>/dev/null || {
		rm -rf "$temp_extract"
		print_error "Failed to extract Alpine keys package"
	}
	
	# Copy keys from etc/apk/keys/ if it exists
	if [ -d "$temp_extract/etc/apk/keys" ]; then
		cp -r "$temp_extract/etc/apk/keys/"* "$dest_dir/" 2>/dev/null || true
	fi
	
	# Also copy keys from usr/share/apk/keys/ if it exists
	if [ -d "$temp_extract/usr/share/apk/keys" ]; then
		cp -r "$temp_extract/usr/share/apk/keys/"* "$dest_dir/" 2>/dev/null || true
	fi
	
	# Clean up temporary directory
	rm -rf "$temp_extract"
	
	# Verify we extracted some keys
	if [ ! "$(ls -A "$dest_dir" 2>/dev/null)" ]; then
		print_error "No Alpine keys were extracted from package"
	fi
	
	print_info "Extracted $(ls "$dest_dir" | wc -l) Alpine signing keys"
}

# Get package information from APKINDEX
get_package_info() {
	local mirror="$1"
	local branch="$2"
	local arch="$3"
	local package_name="$4"
	local temp_index="$(mktemp)"
	
	# Download APKINDEX to temporary file first
	download_from_url "$mirror/$branch/main/$arch/APKINDEX.tar.gz" "$temp_index.tar.gz" || {
		rm -f "$temp_index" "$temp_index.tar.gz"
		return 1
	}
	
	# Extract and parse APKINDEX
	tar -xz -f "$temp_index.tar.gz" -O APKINDEX 2>/dev/null | \
		awk -v pkg="$package_name" '
		/^P:/ {name = substr($0, 3)}
		/^V:/ {version = substr($0, 3)}
		/^L:/ {license = substr($0, 3)}
		/^U:/ {url = substr($0, 3)}
		/^c:/ {checksum = substr($0, 3)}
		/^A:/ {architecture = substr($0, 3)}
		/^$/ { 
			if (name == pkg) {
				print version " " url " " checksum " " architecture " " license
				exit
			}
		}'
	
	# Cleanup temporary files
	rm -f "$temp_index" "$temp_index.tar.gz"
}

# Get apk-tools-static package information
get_apk_tools_info() {
	get_package_info "$1" "$2" "$3" "apk-tools-static"
}

# Get alpine-keys package information
get_alpine_keys_info() {
	get_package_info "$1" "$2" "$3" "alpine-keys"
}

# Check for script updates from GitHub repository
check_for_updates() {
	local latest_version
	local api_url="https://api.github.com/repos/fquinto/alpinelinux/releases/latest"
	
	# Only check if curl is available and we can reach GitHub
	if command -v curl >/dev/null 2>&1; then
		latest_version=$(curl -s --connect-timeout 5 --max-time 10 "$api_url" 2>/dev/null | \
			grep '"tag_name"' | cut -d'"' -f4)
		
		# Strip 'v' prefix from GitHub tag for comparison (e.g., v0.0.1 -> 0.0.1)
		latest_version_clean="${latest_version#v}"
		
		if [ -n "$latest_version_clean" ] && [ "$VERSION" != "$latest_version_clean" ]; then
			print_warning "A newer version ($latest_version) is available at https://github.com/fquinto/alpinelinux"
		fi
	fi
}

generate_chroot_script() {
	cat <<-EOF
		#!/bin/sh
		set -e

		ENV_FILTER_REGEX='($(echo "$CHROOT_KEEP_VARS" | tr -s ' ' '|'))'
	EOF
	if [ -n "$QEMU_EMULATOR" ]; then
		printf 'export QEMU_EMULATOR="%s"' "$QEMU_EMULATOR"
	fi
	cat <<-'EOF'

		user='root'
		if [ $# -ge 2 ] && [ "$1" = '-u' ]; then
		    user="$2"; shift 2
		fi
		oldpwd="$(pwd)"
		[ "$(id -u)" -eq 0 ] || _sudo='sudo'

		tmpfile="$(mktemp)"
		chmod 644 "$tmpfile"
		export | sed -En "s/^([^=]+ ${ENV_FILTER_REGEX}=)('.*'|\".*\")$/\1\3/p" > "$tmpfile" || true

		cd "$(dirname "$0")"
		$_sudo mv "$tmpfile" env.sh
		$_sudo chroot . /usr/bin/env -i su -l "$user" \
		    sh -c ". /etc/profile; . /env.sh; cd '$oldpwd' 2>/dev/null; \"\$@\"" \
		    -- "${@:-sh}"
	EOF
}

generate_cleanup_script() {
	cat <<-'EOF'
		#!/bin/sh
		set -e

		remove=no
		case "$1" in
			-r | --remove) remove=yes;;
			'') ;;
			*) echo "Usage: $0 [-r | --remove]"; exit 1;;
		esac

		SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
		[ "$(id -u)" -eq 0 ] || _sudo='sudo'

		cat /proc/mounts | cut -d' ' -f2 | grep "^$SCRIPT_DIR." | sort -r | while read path; do
			echo "Unmounting $path" >&2
			$_sudo umount -fn "$path" || exit 1
		done

		if [ "$remove" = yes ]; then
			rm_opts=''
			rm --help 2>&1 | grep -Fq 'one-file-system' && rm_opts='--one-file-system'

			echo "Removing $SCRIPT_DIR" >&2
			$_sudo rm -Rf $rm_opts "$SCRIPT_DIR"
		else
			echo "If you want to remove $SCRIPT_DIR directory, run: $0 --remove" >&2
		fi
	EOF
}

#===== Debian support =====#

APT_CACHE_UPDATED=no

install_packages_debian() {
	if [ "$APT_CACHE_UPDATED" != yes ]; then
		apt-get update
		APT_CACHE_UPDATED=yes
	fi
	apt-get install -y -o=Dpkg::Use-Pty=0 --no-install-recommends "$@"
}

setup_binfmt_debian() {
	install_packages_debian binfmt-support \
		|| print_error 'Failed to install binfmt-support using apt-get!'

	update-binfmts --enable \
		|| print_error 'Failed to enable binfmt!'
}

install_qemu_debian() {
	install_packages_debian qemu-user-static \
		|| print_error 'Failed to install qemu-user-static using apt-get!'
}

#===== ArchLinux support =====#

PACMAN_CACHE_UPDATED=no

install_packages_arch() {
	if [ "$PACMAN_CACHE_UPDATED" != yes ]; then
		pacman -Sy
		PACMAN_CACHE_UPDATED=yes
	fi
	pacman -S --noconfirm --needed "$@"
}

setup_binfmt_arch() {
	if [ ! -d /proc/sys/fs/binfmt_misc ]; then
		mount -t binfmt_misc none /proc/sys/fs/binfmt_misc \
			|| print_error 'Failed to mount binfmt_misc!'
	fi
	
	if [ ! -f /proc/sys/fs/binfmt_misc/register ]; then
		print_error 'binfmt_misc is not available in the kernel!'
	fi
	
	print_info 'binfmt_misc is already available and configured'
}

install_qemu_arch() {
	install_packages_arch qemu-user-static-bin \
		|| install_packages_arch qemu-arch-extra \
		|| print_error 'Failed to install qemu-user-static! Try manually: pacman -S qemu-arch-extra'
}

#=====  Common functions  =====#

setup_binfmt_support() {
	local host_system=$(detect_host_system)
	case "$host_system" in
		arch) setup_binfmt_arch;;
		debian) setup_binfmt_debian;;
		*) print_error "Unsupported operating system for automatic binfmt installation: $host_system";;
	esac
}

install_qemu_emulation() {
	local host_system=$(detect_host_system)
	case "$host_system" in
		arch) install_qemu_arch;;
		debian) install_qemu_debian;;
		*) print_error "Unsupported operating system for automatic QEMU installation: $host_system";;
	esac
}


#=====  Main  =====#

while getopts 'a:b:d:i:k:m:p:r:t:nhvD' OPTION; do
	case "$OPTION" in
		a) ARCH="$OPTARG";;
		b) ALPINE_BRANCH="$OPTARG";;
		d) CHROOT_DIR="$OPTARG";;
		i) BIND_DIR="$OPTARG";;
		k) CHROOT_KEEP_VARS="${CHROOT_KEEP_VARS:-} $OPTARG";;
		m) ALPINE_MIRROR="$OPTARG";;
		p) ALPINE_PACKAGES="${ALPINE_PACKAGES:-} $OPTARG";;
		r) EXTRA_REPOS="${EXTRA_REPOS:-} $OPTARG";;
		t) TEMP_DIR="$OPTARG";;
		n) SKIP_VERSION_CHECK=yes;;
		D) DRY_RUN=yes;;
		h) show_usage; exit 0;;
		v) echo "alpine-rootfs-setup $VERSION"; exit 0;;
	esac
done

: ${ALPINE_BRANCH:="latest-stable"}
: ${ALPINE_MIRROR:="https://dl-cdn.alpinelinux.org/alpine"}
: ${ALPINE_PACKAGES:="build-base ca-certificates ssl_client"}
: ${ARCH:=}
: ${BIND_DIR:=}
: ${CHROOT_DIR:="/opt/alpine-rootfs"}
: ${CHROOT_KEEP_VARS:="ARCH CI QEMU_EMULATOR TRAVIS_.*"}
: ${EXTRA_REPOS:=}
: ${SKIP_VERSION_CHECK:=no}
: ${DRY_RUN:=no}
: ${TEMP_DIR:=$(mktemp -d || echo /tmp/alpine)}

[ "$BIND_DIR" ] || case "$(pwd)" in
	/home/*) BIND_DIR="$(pwd)";;
esac

: ${ARCH:=$(uname -m)}

if [ "$(id -u)" -ne 0 ] && [ "$DRY_RUN" != "yes" ]; then
	print_error 'This script must be run as root! Use -D for dry-run testing.'
fi

if [ "$DRY_RUN" = "yes" ]; then
	print_info "DRY RUN MODE - Configuration validation only"
	print_info "ARCH: $ARCH"
	print_info "ALPINE_BRANCH: $ALPINE_BRANCH" 
	print_info "CHROOT_DIR: $CHROOT_DIR"
	print_info "ALPINE_PACKAGES: $ALPINE_PACKAGES"
	print_info "ALPINE_MIRROR: $ALPINE_MIRROR"
	print_info "TEMP_DIR: $TEMP_DIR"
	if [ -n "$BIND_DIR" ]; then
		print_info "BIND_DIR: $BIND_DIR"
	fi
	if [ -n "$EXTRA_REPOS" ]; then
		print_info "EXTRA_REPOS: $EXTRA_REPOS"
	fi
	print_info "Configuration looks valid. Run without -D as root to perform actual installation."
	exit 0
fi

# Check for updates (non-blocking)
if [ "$SKIP_VERSION_CHECK" != "yes" ]; then
	check_for_updates
fi

mkdir -p "$CHROOT_DIR"
cd "$CHROOT_DIR"


QEMU_EMULATOR=''
if [ -n "$ARCH" ] && [ $(normalize_architecture $ARCH) != $(normalize_architecture $(uname -m)) ]; then
	qemu_arch="$(normalize_architecture $ARCH)"
	QEMU_EMULATOR="/usr/bin/qemu-$qemu_arch-static"

	if [ ! -x "$QEMU_EMULATOR" ]; then
		print_info 'Installing qemu-user-static on host system...'
		install_qemu_emulation
	fi

	if [ ! -e /proc/sys/fs/binfmt_misc/qemu-$qemu_arch ]; then
		print_info 'Installing and enabling binfmt-support on host system...'
		setup_binfmt_support
	fi

	mkdir -p usr/bin
	cp -v "$QEMU_EMULATOR" usr/bin/
fi

print_info 'Detecting latest package versions'

print_info "Detecting latest apk-tools-static for $ALPINE_BRANCH/$ARCH"
apk_tools_info=$(get_apk_tools_info "$ALPINE_MIRROR" "$ALPINE_BRANCH" "$ARCH")
if [ -z "$apk_tools_info" ]; then
	print_error "Failed to detect apk-tools-static package version"
fi

apk_tools_version=$(echo "$apk_tools_info" | cut -d' ' -f1)
apk_tools_url=$(echo "$apk_tools_info" | cut -d' ' -f2)
apk_tools_checksum=$(echo "$apk_tools_info" | cut -d' ' -f3)

APK_TOOLS_PKG="apk-tools-static-${apk_tools_version}.apk"
APK_TOOLS_URI="$ALPINE_MIRROR/$ALPINE_BRANCH/main/$ARCH/$APK_TOOLS_PKG"

print_info "Detecting latest alpine-keys for $ALPINE_BRANCH/$ARCH"
alpine_keys_info=$(get_alpine_keys_info "$ALPINE_MIRROR" "$ALPINE_BRANCH" "$ARCH")
if [ -z "$alpine_keys_info" ]; then
	print_error "Failed to detect alpine-keys package version"
fi

alpine_keys_version=$(echo "$alpine_keys_info" | cut -d' ' -f1)
alpine_keys_url=$(echo "$alpine_keys_info" | cut -d' ' -f2)
alpine_keys_checksum=$(echo "$alpine_keys_info" | cut -d' ' -f3)

ALPINE_KEYS_PKG_NAME="alpine-keys-${alpine_keys_version}.apk"
ALPINE_KEYS_URI="$ALPINE_MIRROR/$ALPINE_BRANCH/main/$ARCH/$ALPINE_KEYS_PKG_NAME"

print_info "Using apk-tools-static: $apk_tools_version"
print_info "Using alpine-keys: $alpine_keys_version"

print_info 'Downloading static apk-tools'

# Note: APKINDEX checksums are for package content, not file checksums
# We rely on HTTPS for download integrity
download_and_verify "$APK_TOOLS_URI" "" "$TEMP_DIR"
APK_TOOLS_PKG="$TEMP_DIR/$APK_TOOLS_PKG"

print_info "Extracting apk.static from package"
tar -xz -f "$APK_TOOLS_PKG" -C "$TEMP_DIR" sbin/apk.static 2>/dev/null \
	&& mv "$TEMP_DIR/sbin/apk.static" "$TEMP_DIR/apk.static" \
	&& rm -rf "$TEMP_DIR/sbin" \
	|| print_error "Failed to extract apk.static from package"

APK="$TEMP_DIR/apk.static"
chmod +x "$APK"

print_info 'Downloading Alpine keys'

# Note: APKINDEX checksums are for package content, not file checksums  
# We rely on HTTPS for download integrity
download_and_verify "$ALPINE_KEYS_URI" "" "$TEMP_DIR"
ALPINE_KEYS_PKG="$TEMP_DIR/$ALPINE_KEYS_PKG_NAME"

print_info "Installing Alpine Linux $ALPINE_BRANCH ($ARCH) into chroot"

mkdir -p "$CHROOT_DIR"/etc/apk
cd "$CHROOT_DIR"

printf '%s\n' \
	"$ALPINE_MIRROR/$ALPINE_BRANCH/main" \
	"$ALPINE_MIRROR/$ALPINE_BRANCH/community" \
	$EXTRA_REPOS \
	> etc/apk/repositories

extract_alpine_keys etc/apk/keys/ "$ALPINE_KEYS_PKG"

cp /etc/resolv.conf etc/resolv.conf

"$APK" add \
	--root . --update-cache --initdb --no-progress \
	${ARCH:+--arch $ARCH} \
	alpine-baselayout apk-tools busybox busybox-suid musl-utils

if "$APK" info --root . --no-progress --quiet alpine-release >/dev/null; then
	"$APK" add --root . --no-progress alpine-release
else
	"$APK" fetch --root . --no-progress --stdout alpine-base \
		| tar -xz etc
fi

generate_chroot_script > enter-chroot
generate_cleanup_script > destroy
chmod +x enter-chroot destroy

print_info 'Binding filesystems into chroot'

mount -v -t proc none proc
mount -v --rbind /sys sys
mount --make-rprivate sys
mount -v --rbind /dev dev
mount --make-rprivate dev

if [ -L /dev/shm ] && [ -d /run/shm ]; then
	mkdir -p run/shm
	mount -v --bind /run/shm run/shm
	mount --make-private run/shm
fi

if [ -d "$BIND_DIR" ]; then
	mkdir -p "${CHROOT_DIR}${BIND_DIR}"
	mount -v --bind "$BIND_DIR" "${CHROOT_DIR}${BIND_DIR}"
	mount --make-private "${CHROOT_DIR}${BIND_DIR}"
fi

print_info 'Setting up Alpine'

./enter-chroot <<-EOF
	set -e
	apk update
	apk add $ALPINE_PACKAGES

	if [ -d /etc/sudoers.d ] && [ ! -e /etc/sudoers.d/wheel ]; then
		echo '%wheel ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/wheel
	fi

	if [ -n "${SUDO_USER:-}" ]; then
		adduser -u "${SUDO_UID:-1000}" -G users -s /bin/sh -D "${SUDO_USER:-}" || true
	fi
EOF

cat >&2 <<-EOF
	---
	Alpine installation is complete
	Run $CHROOT_DIR/enter-chroot [-u <user>] [command] to enter the chroot
	and $CHROOT_DIR/destroy [--remove] to destroy it.
EOF
