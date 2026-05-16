#!/usr/bin/env bash
# =============================================================================
# rdma_env.sh â€” RDMA/UCX environment for WITS HPC job scripts
# Location: /cluster/scripts/slurm/templates/rdma_env.sh
#
# Usage in any job script:
#   source /cluster/scripts/slurm/templates/rdma_env.sh
#
# To validate the environment before submitting:
#   bash /cluster/scripts/slurm/templates/rdma_env.sh --check
# =============================================================================

# â”€â”€ Detect IB device name â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
# Auto-detects the mlx5 device rather than hardcoding â€” safer across nodes
_detect_ib_device() {
    local dev
    # Try ibstat first (most reliable)
    dev=$(ibstat 2>/dev/null | grep "^CA '" | head -1 | sed "s/CA '//;s/'//")
    if [[ -n "${dev}" ]]; then
        # Get the first active port number
        local port
        port=$(ibstat "${dev}" 2>/dev/null | awk '/Port [0-9]+:/{p=$2} /State: Active/{print p; exit}' | tr -d ':')
        port=${port:-1}
        echo "${dev}:${port}"
        return
    fi
    # Fallback: scan /sys for mlx5 devices
    for d in /sys/class/infiniband/mlx5_*; do
        [[ -d "${d}" ]] && echo "$(basename ${d}):1" && return
    done
    echo ""
}

# â”€â”€ Set UCX environment â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

IB_DEVICE=$(_detect_ib_device)

if [[ -n "${IB_DEVICE}" ]]; then
    export UCX_NET_DEVICES="${IB_DEVICE}"
else
    # No IB device found â€” UCX will auto-select (may fall back to TCP)
    unset UCX_NET_DEVICES
fi

# Transport priority: rc_mlx5 (RDMA) â†’ ud_mlx5 â†’ shared memory â†’ loopback
# Explicitly exclude TCP so UCX never silently falls back to slow path
export UCX_TLS="rc_mlx5,ud_mlx5,dc_mlx5,sm,self"

# Rendezvous threshold â€” messages above this size use true zero-copy RDMA
# 8192 bytes (8 KB) is a good default for NDR; lower = more RDMA operations
export UCX_RNDV_THRESH=8192

# Zero-copy put for rendezvous â€” best for NDR fabric
export UCX_RNDV_SCHEME="put_zcopy"

# Memory registration cache â€” avoids re-pinning the same memory regions
# Critical for performance: without this, every MPI call re-registers memory
export UCX_MEMTYPE_CACHE=y
export UCX_RCACHE_ENABLE=y

# Cache size: ~10% of node RAM (768 GB nodes â†’ ~75 GB cache)
export UCX_RCACHE_MAX_SIZE=75161927680

# InfiniBand tuning
export UCX_IB_GID_INDEX=0
export UCX_IB_TRAFFIC_CLASS=0
export UCX_IB_RX_QUEUE_LEN=4096
export UCX_IB_TX_QUEUE_LEN=4096

# Force OpenMPI to use UCX â€” disable legacy BTL and openib
export OMPI_MCA_pml="ucx"
export OMPI_MCA_btl="^tcp,openib"
export OMPI_MCA_osc="ucx"

# MPI launch interface â€” pmix_v4 matches your PMIx install
export OMPI_MCA_mpi_pmix="pmix"

# â”€â”€ Self-check mode â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
# Run: bash rdma_env.sh --check
# This validates the environment without running a job

if [[ "${1:-}" == "--check" ]]; then

    RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
    PASS=0; FAIL=0; WARN=0

    ok()   { echo -e "${GREEN}[PASS]${NC} $*"; ((PASS++)); }
    fail() { echo -e "${RED}[FAIL]${NC} $*"; ((FAIL++)); }
    warn() { echo -e "${YELLOW}[WARN]${NC} $*"; ((WARN++)); }

    echo ""
    echo "================================================================"
    echo " RDMA environment validation â€” $(hostname)"
    echo "================================================================"
    echo ""

    # 1. UCX binary exists
    if command -v ucx_info &>/dev/null; then
        UCX_VER=$(ucx_info -v 2>/dev/null | grep "UCX version" | awk '{print $NF}')
        ok "UCX installed: ${UCX_VER}"
    else
        fail "ucx_info not found â€” UCX not installed or not in PATH"
        echo "    Fix: sudo bash UCX_build.sh"
    fi

    # 2. DOCA-OFED / IB driver loaded
    if lsmod 2>/dev/null | grep -q mlx5_core; then
        ok "mlx5_core kernel module: loaded"
    else
        fail "mlx5_core not loaded â€” DOCA-OFED may not be installed"
        echo "    Fix: Install DOCA-OFED from your Notion doc, then reboot"
    fi

    # 3. IB device detected
    if [[ -n "${IB_DEVICE}" ]]; then
        ok "IB device detected: ${IB_DEVICE}"
    else
        fail "No IB device found (ibstat returned nothing)"
        echo "    Fix: Check cables are connected and DOCA-OFED is installed"
    fi

    # 4. IB port state
    if ibstat 2>/dev/null | grep -q "State: Active"; then
        ok "IB port state: Active"
    elif ibstat 2>/dev/null | grep -q "State: Initializing"; then
        warn "IB port state: Initializing (switch may still be coming up)"
    else
        fail "IB port not Active â€” check cables and switch power"
    fi

    # 5. rc_mlx5 transport available
    if ucx_info -d 2>/dev/null | grep -q "rc_mlx5"; then
        ok "rc_mlx5 transport: available (full RDMA)"
    else
        fail "rc_mlx5 not found in UCX transport list"
        echo "    Fix: UCX was likely built before DOCA-OFED was installed"
        echo "         Reinstall: sudo bash UCX_build.sh"
    fi

    # 6. UCX version is new enough for NDR
    if command -v ucx_info &>/dev/null; then
        UCX_MAJOR=$(ucx_info -v 2>/dev/null | grep "UCX version" | \
            awk '{print $NF}' | cut -d. -f1)
        UCX_MINOR=$(ucx_info -v 2>/dev/null | grep "UCX version" | \
            awk '{print $NF}' | cut -d. -f2)
        if [[ "${UCX_MAJOR}" -gt 1 ]] || \
           [[ "${UCX_MAJOR}" -eq 1 && "${UCX_MINOR}" -ge 15 ]]; then
            ok "UCX version ${UCX_MAJOR}.${UCX_MINOR}: NDR-capable"
        else
            fail "UCX ${UCX_MAJOR}.${UCX_MINOR} is too old for NDR â€” need 1.15+"
            echo "    Fix: sudo bash UCX_build.sh (builds 1.17.0)"
        fi
    fi

    # 7. libibverbs linked correctly
    if ldconfig -p 2>/dev/null | grep -q "libibverbs"; then
        ok "libibverbs: found in library cache"
    else
        warn "libibverbs not in ldconfig cache â€” run: sudo ldconfig"
    fi

    # 8. Environment variables set correctly
    echo ""
    echo "--- Environment variables ---"
    for var in UCX_NET_DEVICES UCX_TLS UCX_RNDV_THRESH UCX_RNDV_SCHEME \
               UCX_MEMTYPE_CACHE UCX_RCACHE_ENABLE OMPI_MCA_pml OMPI_MCA_btl; do
        if [[ -n "${!var:-}" ]]; then
            printf "  %-30s = %s\n" "${var}" "${!var}"
        else
            warn "${var} is not set"
        fi
    done

    # 9. Summary
    echo ""
    echo "================================================================"
    echo -e " PASS: ${GREEN}${PASS}${NC}  FAIL: ${RED}${FAIL}${NC}  WARN: ${YELLOW}${WARN}${NC}"
    echo "================================================================"

    if [[ ${FAIL} -eq 0 ]]; then
        echo -e " ${GREEN}Environment is ready. RDMA will be used for MPI jobs.${NC}"
    else
        echo -e " ${RED}${FAIL} issue(s) found. Fix before running MPI jobs.${NC}"
    fi
    echo ""

    exit ${FAIL}
fi

# â”€â”€ When sourced: print a one-line status â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
if [[ "${BASH_SOURCE[0]}" != "${0}" ]]; then
    if [[ -n "${IB_DEVICE}" ]]; then
        echo "[rdma_env] UCX RDMA configured: device=${IB_DEVICE} tls=${UCX_TLS}"
    else
        echo "[rdma_env] WARNING: No IB device found â€” UCX will auto-select transport"
    fi
fi
