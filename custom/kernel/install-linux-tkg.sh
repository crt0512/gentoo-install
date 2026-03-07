#!/usr/bin/env bash
set -euo pipefail

# linux-tkg custom kernel pipeline for oddlama/gentoo-install.
# Executed inside target system (chroot) by gentoo.conf after_install hook.
#
# This script intentionally keeps the flow mostly interactive because linux-tkg's
# install script asks many build-tuning questions unless fully preseeded.

REPO_URL="https://github.com/Frogging-Family/linux-tkg.git"
REPO_DIR="/usr/local/src/linux-tkg"
GIT_REF="main"
ACTION="install" # install|config
FORCE_RUNNING_CONFIG="auto" # auto|true|false
DO_MODULE_REBUILD="false"
INSTALL_DEPS="true"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CUSTOMIZATION_SOURCE="${SCRIPT_DIR}/linux-tkg.customization.cfg"
TUNING_PROFILE="auto" # auto|intel-alderlake|intel-generic|amd-generic|none

# Optional linux-tkg customization knobs (written into customization.cfg)
TKG_VERSION=""            # examples: 6.12, 6.12.25, 6.6-latest
TKG_CPUSCHED=""           # eevdf|cfs|bore|pds|bmq|...
TKG_COMPILER=""           # gcc|llvm
TKG_KERNEL_LOCALVERSION="" # appended into tkg kernel flavor name

usage() {
  cat <<'EOF'
Usage: install-linux-tkg.sh [options]

Options:
  --repo-dir <path>             Clone/update directory (default: /usr/local/src/linux-tkg)
  --git-ref <ref>               Branch/tag/commit to checkout (default: main)
  --action <install|config>     linux-tkg action (default: install)
  --customization-source <path> Customization file to copy before build
                                (default: script-dir/linux-tkg.customization.cfg)
  --tuning-profile <name>       Apply CPU tuning overrides:
                                auto|intel-alderlake|intel-generic|amd-generic|none
                                (default: auto)
  --force-running-config <auto|true|false>
                                On OpenRC, running-kernel config is usually safer.
  --install-deps <true|false>   Emerge common build dependencies first (default: true)
  --module-rebuild <true|false> Run emerge @module-rebuild after install (default: false)
  --version <value>             Set _version in customization.cfg
  --cpusched <value>            Set _cpusched in customization.cfg
  --compiler <gcc|llvm>         Set _compiler in customization.cfg
  --localversion <value>        Set _kernel_localversion in customization.cfg
  -h, --help                    Show this help

Examples:
  install-linux-tkg.sh --action install --cpusched eevdf --compiler gcc
  install-linux-tkg.sh --force-running-config true --version 6.12
EOF
}

log() {
  printf '[linux-tkg-hook] %s\n' "$*"
}

die() {
  printf '[linux-tkg-hook] ERROR: %s\n' "$*" >&2
  exit 1
}

is_true() {
  [[ "$1" == "true" || "$1" == "1" || "$1" == "yes" ]]
}

detect_openrc() {
  if command -v rc-update >/dev/null 2>&1 && ! [[ -d /run/systemd/system ]]; then
    return 0
  fi
  return 1
}

detect_cpu_tuning_profile() {
  local vendor=""
  local model_name=""

  if [[ -r /proc/cpuinfo ]]; then
    vendor="$(awk -F': *' '/^vendor_id/ {print $2; exit}' /proc/cpuinfo || true)"
    model_name="$(awk -F': *' '/^model name/ {print $2; exit}' /proc/cpuinfo || true)"
  fi

  case "$vendor" in
    GenuineIntel)
      if [[ "$model_name" =~ (Alder|Raptor|13th[[:space:]]Gen|14th[[:space:]]Gen|i9-14900|i7-14700|i5-14600|i9-13900|i7-13700|i5-13600|i9-12900|i7-12700|i5-12600) ]]; then
        echo "intel-alderlake"
      else
        echo "intel-generic"
      fi
      ;;
    AuthenticAMD)
      echo "amd-generic"
      ;;
    *)
      echo "intel-generic"
      ;;
  esac
}

apply_tuning_profile() {
  local file="$1"
  local profile="$2"

  case "$profile" in
    intel-alderlake)
      upsert_cfg_var "$file" "_processor_opt" "alderlake"
      upsert_cfg_var "$file" "KCFLAGS" "-march=alderlake -O3 -pipe -mabm -mno-kl -mno-sgx -mno-widekl -mshstk --param=l1-cache-line-size=64 --param=l1-cache-size=32 --param=l2-cache-size=36864"
      upsert_cfg_var "$file" "KCPPFLAGS" "-march=alderlake -O3 -pipe"
      upsert_cfg_var "$file" "_custom_commandline" "intel_pstate=passive kernel.split_lock_mitigate=0 mitigations=off"
      ;;
    intel-generic)
      upsert_cfg_var "$file" "_processor_opt" "native"
      upsert_cfg_var "$file" "KCFLAGS" "-march=native -O3 -pipe"
      upsert_cfg_var "$file" "KCPPFLAGS" "-march=native -O3 -pipe"
      upsert_cfg_var "$file" "_custom_commandline" "intel_pstate=passive kernel.split_lock_mitigate=0 mitigations=off"
      ;;
    amd-generic)
      upsert_cfg_var "$file" "_processor_opt" "native"
      upsert_cfg_var "$file" "KCFLAGS" "-march=native -O3 -pipe"
      upsert_cfg_var "$file" "KCPPFLAGS" "-march=native -O3 -pipe"
      upsert_cfg_var "$file" "_custom_commandline" "mitigations=off"
      ;;
    none)
      ;;
    *)
      die "Unknown tuning profile: $profile"
      ;;
  esac
}

upsert_cfg_var() {
  local file="$1"
  local key="$2"
  local value="$3"

  if grep -Eq "^[[:space:]]*${key}=" "$file"; then
    sed -i -E "s|^[[:space:]]*${key}=.*|${key}=\"${value}\"|" "$file"
  else
    printf '%s\n' "${key}=\"${value}\"" >> "$file"
  fi
}

ensure_dependencies() {
  local deps=(
    app-alternatives/awk
    app-arch/cpio
    app-arch/lz4
    app-arch/zstd
    dev-vcs/git
    dev-build/bison
    dev-build/flex
    dev-lang/perl
    sys-apps/kmod
    sys-devel/bc
    sys-devel/binutils
    sys-devel/gcc
    sys-kernel/pahole
    sys-libs/ncurses
    virtual/libelf
    dev-libs/openssl
  )

  log "Installing linux-tkg build dependencies (best-effort via emerge --noreplace)"
  emerge --verbose --noreplace "${deps[@]}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo-dir)
      REPO_DIR="${2:-}"
      shift 2
      ;;
    --git-ref)
      GIT_REF="${2:-}"
      shift 2
      ;;
    --action)
      ACTION="${2:-}"
      shift 2
      ;;
    --customization-source)
      CUSTOMIZATION_SOURCE="${2:-}"
      shift 2
      ;;
    --tuning-profile)
      TUNING_PROFILE="${2:-}"
      shift 2
      ;;
    --force-running-config)
      FORCE_RUNNING_CONFIG="${2:-}"
      shift 2
      ;;
    --install-deps)
      INSTALL_DEPS="${2:-}"
      shift 2
      ;;
    --module-rebuild)
      DO_MODULE_REBUILD="${2:-}"
      shift 2
      ;;
    --version)
      TKG_VERSION="${2:-}"
      shift 2
      ;;
    --cpusched)
      TKG_CPUSCHED="${2:-}"
      shift 2
      ;;
    --compiler)
      TKG_COMPILER="${2:-}"
      shift 2
      ;;
    --localversion)
      TKG_KERNEL_LOCALVERSION="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "Unknown argument: $1"
      ;;
  esac
done

[[ "$ACTION" =~ ^(install|config)$ ]] || die "--action must be install or config"
[[ "$FORCE_RUNNING_CONFIG" =~ ^(auto|true|false)$ ]] || die "--force-running-config must be auto|true|false"
[[ "$INSTALL_DEPS" =~ ^(true|false|1|0|yes|no)$ ]] || die "--install-deps expects true/false"
[[ "$DO_MODULE_REBUILD" =~ ^(true|false|1|0|yes|no)$ ]] || die "--module-rebuild expects true/false"
[[ "$TUNING_PROFILE" =~ ^(auto|intel-alderlake|intel-generic|amd-generic|none)$ ]] || die "--tuning-profile must be auto|intel-alderlake|intel-generic|amd-generic|none"

[[ $EUID -eq 0 ]] || die "Run as root"

if ! command -v emerge >/dev/null 2>&1; then
  die "Portage (emerge) not found. This script is for Gentoo targets."
fi

if is_true "$INSTALL_DEPS"; then
  ensure_dependencies
fi

mkdir -p "$(dirname "$REPO_DIR")"
if [[ -d "$REPO_DIR/.git" ]]; then
  log "Updating existing linux-tkg repo at $REPO_DIR"
  git -C "$REPO_DIR" fetch --all --tags
else
  log "Cloning linux-tkg into $REPO_DIR"
  git clone "$REPO_URL" "$REPO_DIR"
fi

git -C "$REPO_DIR" checkout "$GIT_REF"
git -C "$REPO_DIR" pull --ff-only || true

CFG_FILE="$REPO_DIR/customization.cfg"
[[ -f "$CFG_FILE" ]] || die "customization.cfg not found at $CFG_FILE"
cp "$CFG_FILE" "${CFG_FILE}.bak.$(date +%Y%m%d-%H%M%S)"

if [[ -n "$CUSTOMIZATION_SOURCE" && -f "$CUSTOMIZATION_SOURCE" ]]; then
  log "Applying project customization from $CUSTOMIZATION_SOURCE"
  cp "$CUSTOMIZATION_SOURCE" "$CFG_FILE"
else
  log "No customization source found at '$CUSTOMIZATION_SOURCE', using repo defaults"
fi

if [[ "$TUNING_PROFILE" == "auto" ]]; then
  TUNING_PROFILE="$(detect_cpu_tuning_profile)"
fi
log "Applying tuning profile: $TUNING_PROFILE"
apply_tuning_profile "$CFG_FILE" "$TUNING_PROFILE"

# Ensure Gentoo mode so install.sh follows Gentoo path.
upsert_cfg_var "$CFG_FILE" "_distro" "Gentoo"

# For OpenRC targets, running-kernel config is usually safer.
case "$FORCE_RUNNING_CONFIG" in
  true)
    upsert_cfg_var "$CFG_FILE" "_configfile" "running-kernel"
    ;;
  false)
    :
    ;;
  auto)
    if detect_openrc; then
      upsert_cfg_var "$CFG_FILE" "_configfile" "running-kernel"
    fi
    ;;
esac

[[ -n "$TKG_VERSION" ]] && upsert_cfg_var "$CFG_FILE" "_version" "$TKG_VERSION"
[[ -n "$TKG_CPUSCHED" ]] && upsert_cfg_var "$CFG_FILE" "_cpusched" "$TKG_CPUSCHED"
[[ -n "$TKG_COMPILER" ]] && upsert_cfg_var "$CFG_FILE" "_compiler" "$TKG_COMPILER"
[[ -n "$TKG_KERNEL_LOCALVERSION" ]] && upsert_cfg_var "$CFG_FILE" "_kernel_localversion" "$TKG_KERNEL_LOCALVERSION"

# Keep installation behavior explicit to avoid unattended surprises.
upsert_cfg_var "$CFG_FILE" "_install_after_building" "prompt"

cd "$REPO_DIR"
log "Starting linux-tkg install flow: ./install.sh $ACTION"
log "You may be prompted by linux-tkg for scheduler/options and install confirmations."
./install.sh "$ACTION"

if is_true "$DO_MODULE_REBUILD"; then
  log "Running module rebuild for external modules"
  emerge @module-rebuild --keep-going
fi

log "linux-tkg hook completed"
log "Reminder: keep a known-good fallback kernel until linux-tkg boots and is validated."
