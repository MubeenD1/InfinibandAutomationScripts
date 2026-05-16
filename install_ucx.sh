#!/usr/bin/env bash
# =============================================================================
# UCX_build.sh — builds UCX 1.20.1 from source
# Run on ALL 4 nodes AFTER DOCA-OFED is installed
#
# Why from source: apt ships UCX 1.14 on Ubuntu 24.04.
# NDR InfiniBand (ConnectX-7) needs UCX 1.15+ for rc_mlx5 NDR support.
# ROCm support added for GPU-accelerated HPL (rocHPL).
#
# Usage: sudo bash UCX_build.sh
# =============================================================================

set -euo pipefail

UCX_VERSION="1.20.1"                  # ← fixed: was missing closing quote
INSTALL_PREFIX="/usr/local"
BUILD_DIR="/tmp/ucx_build"
LOGFILE="/tmp/ucx_build.log"
ROCM_PATH="/opt/rocm"

exec > >(tee -a "$LOGFILE") 2>&1

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
ok()   { echo -e "${GREEN}[OK]${NC}    $*"; }
info() { echo -e "${YELLOW}[INFO]${NC}  $*"; }
die()  { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

[[ $EUID -ne 0 ]] && die "Run as root: sudo bash UCX_build.sh"

echo "================================================================"
echo " UCX ${UCX_VERSION} — Build from source"
echo " Node: $(hostname)  |  $(date)"
echo "================================================================"

# ── Phase 1: verify DOCA-OFED is installed ───────────────────────────────────
info "Phase 1: Checking DOCA-OFED / MLNX_OFED is installed..."

if ! command -v ibstat &>/dev/null; then
    die "ibstat not found. Install DOCA-OFED first (from your Notion doc) then re-run this script."
fi

if ! ldconfig -p | grep -q libibverbs; then
    die "libibverbs not found. DOCA-OFED must be installed before building UCX."
fi

# Detect verbs prefix — DOCA-OFED vs inbox
if pkg-config --exists libibverbs 2>/dev/null; then
    VERBS_PREFIX=$(pkg-config --variable=prefix libibverbs)
    ok "libibverbs found via pkg-config at: ${VERBS_PREFIX}"
elif [[ -f /usr/include/infiniband/verbs.h ]]; then
    VERBS_PREFIX="/usr"
    ok "libibverbs found at: /usr (header check)"
else
    die "libibverbs headers not found. Check DOCA-OFED install."
fi

# ── Phase 2: install build dependencies ──────────────────────────────────────
info "Phase 2: Installing build dependencies..."

apt-get update -qq
apt-get install -y \
    build-essential wget git pkg-config \
    libibverbs-dev \
    librdmacm-dev \
    libnuma-dev \
    libelf-dev \
    binutils-dev \
    autoconf automake libtool

ok "Build dependencies installed."

# ── Phase 3: check ROCm ──────────────────────────────────────────────────────
info "Phase 3: Checking ROCm installation..."

ROCM_FLAG=""
if [[ -d "${ROCM_PATH}" ]]; then
    if [[ -f "${ROCM_PATH}/include/hip/hip_runtime.h" ]]; then
        ROCM_FLAG="--with-rocm=${ROCM_PATH}"
        ok "ROCm found at ${ROCM_PATH} — GPU-aware UCX will be built"
    else
        info "WARNING: ROCm directory exists but HIP headers missing."
        info "         Building without ROCm support."
    fi
else
    info "WARNING: ROCm not found at ${ROCM_PATH}."
    info "         Building without ROCm support."
    info "         Install ROCm first if running rocHPL."
fi

# ── Phase 4: download UCX ────────────────────────────────────────────────────
info "Phase 4: Downloading UCX ${UCX_VERSION}..."

mkdir -p "${BUILD_DIR}"
cd "${BUILD_DIR}"

if [[ ! -f ucx-${UCX_VERSION}.tar.gz ]]; then
    wget -q --show-progress \
        "https://github.com/openucx/ucx/releases/download/v${UCX_VERSION}/ucx-${UCX_VERSION}.tar.gz"
else
    info "Tarball already exists, skipping download."
fi

tar -xzf ucx-${UCX_VERSION}.tar.gz
cd ucx-${UCX_VERSION}

ok "Source extracted."

# ── Phase 5: configure ───────────────────────────────────────────────────────
info "Phase 5: Configuring UCX..."
[[ -n "${ROCM_FLAG}" ]] && info "ROCm flag: ${ROCM_FLAG}" || info "ROCm: disabled"

./configure \
    --prefix="${INSTALL_PREFIX}" \
    --with-verbs="${VERBS_PREFIX}" \
    --with-rdmacm="${VERBS_PREFIX}" \
    --with-libnuma \
    --enable-mt \
    --enable-numa \
    --with-avx \
    --disable-static \
    --enable-optimizations \
    ${ROCM_FLAG} \
    2>&1 | tee /tmp/ucx_configure.log | \
    grep -E "(verbs|rdma|rocm|numa|mlx5|error|warning|configure:)" | head -40 || true

# ── Verify configure results ──────────────────────────────────────────────────
echo ""
info "Checking configure results..."

# IB verbs — hard requirement
if grep -q "with verbs.*yes" /tmp/ucx_configure.log 2>/dev/null; then
    ok "IB verbs:  yes"
else
    echo "--- configure summary (last 30 lines) ---"
    tail -30 /tmp/ucx_configure.log
    die "UCX configure did not find IB verbs. Check DOCA-OFED install and re-run."
fi

# NUMA
if grep -qi "numa.*yes" /tmp/ucx_configure.log 2>/dev/null; then
    ok "NUMA:      yes"
else
    info "WARNING: NUMA support not confirmed — check libnuma-dev is installed"
fi

# ROCm
if [[ -n "${ROCM_FLAG}" ]]; then
    if grep -qi "rocm.*yes\|with rocm.*yes" /tmp/ucx_configure.log 2>/dev/null; then
        ok "ROCm:      yes — GPU-aware MPI enabled"
    else
        info "WARNING: ROCm flag passed but not confirmed — check /tmp/ucx_configure.log"
    fi
fi

ok "Configure complete."

# ── Phase 6: build ───────────────────────────────────────────────────────────
info "Phase 6: Building UCX with $(nproc) cores (takes ~3 minutes)..."

make -j"$(nproc)"

ok "Build complete."

# ── Phase 7: install ─────────────────────────────────────────────────────────
info "Phase 7: Installing to ${INSTALL_PREFIX}..."

make install
ldconfig

ok "UCX ${UCX_VERSION} installed to ${INSTALL_PREFIX}"

# ── Phase 8: verify ──────────────────────────────────────────────────────────
info "Phase 8: Verifying installation..."

UCX_INFO="${INSTALL_PREFIX}/bin/ucx_info"
[[ -f "${UCX_INFO}" ]] || die "ucx_info not found after install"

echo ""
echo "--- UCX version ---"
"${UCX_INFO}" -v

echo ""
echo "--- Transport list (look for rc_mlx5 and rocm) ---"
"${UCX_INFO}" -d 2>/dev/null | grep -E "^# +Transport:|Device:" | head -30 || \
    echo "(Run ucx_info -d manually once IB port is Active)"

# Check rc_mlx5
if "${UCX_INFO}" -d 2>/dev/null | grep -q "rc_mlx5"; then
    ok "rc_mlx5 transport: FOUND — RDMA is available"
elif ibstat 2>/dev/null | grep -q "State: Active"; then
    die "IB port is Active but rc_mlx5 not found — UCX may not have linked against verbs correctly"
else
    info "rc_mlx5 not visible yet — IB port may not be Active (cables/switch)"
    info "Re-run: ucx_info -d  once the IB fabric is up"
fi

# Check rocm transport
if [[ -n "${ROCM_FLAG}" ]]; then
    if "${UCX_INFO}" -d 2>/dev/null | grep -q "rocm"; then
        ok "rocm transport: FOUND — GPU-aware MPI available"
    else
        info "rocm transport not visible yet — verify ROCm is loaded and GPU is present"
        info "Re-run: ucx_info -d  once ROCm is active"
    fi
fi

# ── Done ─────────────────────────────────────────────────────────────────────
echo ""
echo "================================================================"
echo -e " ${GREEN}UCX BUILD COMPLETE${NC}"
echo "================================================================"
echo ""
echo "  Version:     ${UCX_VERSION}"
echo "  Installed:   ${INSTALL_PREFIX}"
echo "  ROCm:        ${ROCM_FLAG:-disabled}"
echo "  Build log:   ${LOGFILE}"
echo "  Config log:  /tmp/ucx_configure.log"
echo ""
echo "  Next steps:"
echo "    1. Repeat on all other nodes"
echo "    2. Check transport list: ucx_info -d | grep -E 'Transport|rocm|mlx5'"
echo "    3. Build OpenMPI: bash OpenMPI_build.sh 5 0 6"
echo "================================================================"
