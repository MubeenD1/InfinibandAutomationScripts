#!/bin/bash
# install_slurm_4node.sh - 4-node Slurm installer built from source with PMIx
# Run on node1 (controller) first, then compute nodes
# Usage: sudo ./install_slurm_4node.sh [controller|compute]
set -e

ROLE=${1:-controller}
CONTROLLER_HOST="node1"
WITS_USER="wits"
SLURM_VERSION="24.11.7"
PMIX_PREFIX="/usr/local/pmix"
SLURM_PREFIX="/usr/local/slurm"

# From your hostfile — mgmt IPs for Slurm only
declare -A MGMT_IPS=(
    [node1]="10.10.0.1"
    [node2]="10.10.0.2"
    [node3]="10.10.0.3"
    [node4]="10.10.0.4"
)

if [ "$EUID" -ne 0 ]; then
    echo "Please run as root (use sudo)."
    exit 1
fi

# Verify PMIx is installed before doing anything
if [ ! -f "${PMIX_PREFIX}/bin/pmix_info" ]; then
    echo "Error: PMIx not found at ${PMIX_PREFIX}. Run install_pmix.sh first on this node."
    exit 1
fi

CURRENT_HOST=$(hostname -s)

echo "=== Cleaning up any previous partial installation ==="
systemctl stop slurmctld slurmd munge 2>/dev/null || true
apt remove --purge -y slurm-wlm slurmctld slurmd slurm-client munge 2>/dev/null || true
rm -rf /etc/slurm /var/spool/slurmctld /var/spool/slurmd
rm -rf /var/log/slurmctld.log /var/log/slurmd.log
rm -rf /etc/munge /var/lib/munge /var/log/munge /run/munge
rm -rf /cluster/logs/slurm/slurmctld.log /cluster/logs/slurm/slurmd.log
userdel slurm 2>/dev/null || true
userdel munge 2>/dev/null || true
groupdel slurm 2>/dev/null || true
groupdel munge 2>/dev/null || true
apt autoremove -y

echo "=== Installing build dependencies ==="
apt update
apt install -y \
    build-essential wget \
    libssl-dev \
    libhwloc-dev \
    libevent-dev \
    libnuma-dev \
    libpam0g-dev \
    libdbus-1-dev \
    libsystemd-dev \
    libjson-c-dev \
    libyaml-dev \
    libhttp-parser-dev \
    libjansson-dev \
    libreadline-dev \
    lua5.4 liblua5.4-dev \
    munge libmunge-dev

echo "=== Creating munge and slurm users ==="
groupadd -g 980 munge 2>/dev/null || true
useradd -m -c "MUNGE Auth" -d /var/lib/munge \
    -u 980 -g munge -s /sbin/nologin munge 2>/dev/null || true
groupadd -g 981 slurm 2>/dev/null || true
useradd -m -c "Slurm WM" -d /var/lib/slurm \
    -u 981 -g slurm -s /bin/bash slurm 2>/dev/null || true

echo "=== Setting up Munge ==="
if [ "$ROLE" = "controller" ]; then
    echo "--- Generating munge key on controller ---"
    /usr/sbin/mungekey --verbose --force
    chown -R munge:munge /etc/munge/ /var/log/munge/ /var/lib/munge /run/munge 2>/dev/null || true
    chmod 0700 /etc/munge/ /var/log/munge/ 2>/dev/null || true
    chmod 400 /etc/munge/munge.key

    systemctl enable munge
    systemctl start munge

    if ! munge -n | unmunge &>/dev/null; then
        echo "Munge local test failed. Exiting."
        exit 1
    fi
    echo "Munge working locally."

    echo "--- Distributing munge key via NFS ---"
    cp /etc/munge/munge.key /home/${WITS_USER}/munge.key
    chmod 644 /home/${WITS_USER}/munge.key
    echo "Munge key at /home/${WITS_USER}/munge.key — run compute script on node2/3/4 now."

else
    echo "--- Compute node: fetching munge key from NFS ---"
    if [ ! -f "/home/${WITS_USER}/munge.key" ]; then
        echo "Error: /home/${WITS_USER}/munge.key not found."
        echo "Make sure NFS is mounted and controller has run this script first."
        exit 1
    fi

    cp /home/${WITS_USER}/munge.key /etc/munge/munge.key
    chown -R munge:munge /etc/munge/ /var/log/munge/ /var/lib/munge /run/munge 2>/dev/null || true
    chmod 0700 /etc/munge/ /var/log/munge/ 2>/dev/null || true
    chmod 400 /etc/munge/munge.key

    systemctl enable munge
    systemctl start munge

    if ! munge -n | unmunge &>/dev/null; then
        echo "Munge local test failed. Exiting."
        exit 1
    fi
    echo "Munge working locally."

    echo "--- Testing cross-node munge back to controller ---"
    if ! munge -n | ssh ${WITS_USER}@${CONTROLLER_HOST} unmunge &>/dev/null; then
        echo "WARNING: Cross-node munge test failed — check SSH keys and munge key consistency."
    else
        echo "Cross-node munge: OK"
    fi
fi

echo "=== Building Slurm ${SLURM_VERSION} from source ==="
cd /tmp
if [ ! -f slurm-${SLURM_VERSION}.tar.bz2 ]; then
    wget https://download.schedmd.com/slurm/slurm-${SLURM_VERSION}.tar.bz2
fi
rm -rf slurm-${SLURM_VERSION}
tar -xjf slurm-${SLURM_VERSION}.tar.bz2
cd slurm-${SLURM_VERSION}
./configure \
    --prefix=${SLURM_PREFIX} \
    --sysconfdir=/etc/slurm \
    --with-pmix=${PMIX_PREFIX} \
    --with-munge \
    --with-hwloc \
    --with-json \
    --enable-pam \
    --with-systemdsystemunitdir=/usr/lib/systemd/system
make -j$(nproc)
make install

echo "=== Adding Slurm to library and binary path ==="
echo "${SLURM_PREFIX}/lib" > /etc/ld.so.conf.d/slurm.conf
ldconfig
ln -sf ${SLURM_PREFIX}/bin/* /usr/local/bin/ 2>/dev/null || true
ln -sf ${SLURM_PREFIX}/sbin/* /usr/local/sbin/ 2>/dev/null || true

echo "=== Writing slurm.conf ==="
# Hardware auto-detected from current node — assumed identical across all 4 nodes
CPUS=$(nproc)
SOCKETS=$(lscpu | awk '/^Socket\(s\):/{print $2}')
CORES_PER_SOCKET=$(lscpu | awk '/^Core\(s\) per socket:/{print $4}')
THREADS_PER_CORE=$(lscpu | awk '/^Thread\(s\) per core:/{print $4}')
MEM_MB=$(free -m | awk '/^Mem:/{print int($2 * 0.95)}')

mkdir -p /etc/slurm

cat > /etc/slurm/slurm.conf <<EOF
# slurm.conf — WITS ASC 4-node Cluster
ClusterName=asc-cluster
SlurmctldHost=${CONTROLLER_HOST}

AuthType=auth/munge
CredType=cred/munge

ProctrackType=proctrack/cgroup
TaskPlugin=task/affinity,task/cgroup
MpiDefault=pmix

SlurmctldPidFile=/var/run/slurmctld.pid
SlurmdPidFile=/var/run/slurmd.pid
SlurmctldPort=6817
SlurmdPort=6818
SlurmdSpoolDir=/var/spool/slurmd
StateSaveLocation=/var/spool/slurmctld
TmpFS=/tmp
SlurmUser=slurm

SlurmctldLogFile=/cluster/logs/slurm/slurmctld.log
SlurmdLogFile=/cluster/logs/slurm/slurmd.log
SlurmctldDebug=debug
SlurmdDebug=debug
JobCompType=jobcomp/none
JobAcctGatherFrequency=30

InactiveLimit=0
KillWait=30
MinJobAge=300
SlurmctldTimeout=120
SlurmdTimeout=300
Waittime=0
ReturnToService=1

SelectType=select/cons_tres
SelectTypeParameters=CR_Core_Memory

PriorityType=priority/basic
PriorityFavorSmall=YES

# NodeAddr = mgmt IP (ethernet) — Slurm control traffic only
# MPI uses IB separately via UCX/OpenMPI, not configured here
NodeName=node1 NodeAddr=${MGMT_IPS[node1]} CPUs=${CPUS} Sockets=${SOCKETS} CoresPerSocket=${CORES_PER_SOCKET} ThreadsPerCore=${THREADS_PER_CORE} RealMemory=${MEM_MB} State=UNKNOWN
NodeName=node2 NodeAddr=${MGMT_IPS[node2]} CPUs=${CPUS} Sockets=${SOCKETS} CoresPerSocket=${CORES_PER_SOCKET} ThreadsPerCore=${THREADS_PER_CORE} RealMemory=${MEM_MB} State=UNKNOWN
NodeName=node3 NodeAddr=${MGMT_IPS[node3]} CPUs=${CPUS} Sockets=${SOCKETS} CoresPerSocket=${CORES_PER_SOCKET} ThreadsPerCore=${THREADS_PER_CORE} RealMemory=${MEM_MB} State=UNKNOWN
NodeName=node4 NodeAddr=${MGMT_IPS[node4]} CPUs=${CPUS} Sockets=${SOCKETS} CoresPerSocket=${CORES_PER_SOCKET} ThreadsPerCore=${THREADS_PER_CORE} RealMemory=${MEM_MB} State=UNKNOWN

PartitionName=brrr Nodes=ALL Default=YES MaxTime=INFINITE State=UP
EOF

chown slurm:slurm /etc/slurm/slurm.conf
chmod 644 /etc/slurm/slurm.conf

echo "=== Writing cgroup.conf ==="
cat > /etc/slurm/cgroup.conf <<EOF
CgroupPlugin=cgroup/v2
EOF
chown slurm:slurm /etc/slurm/cgroup.conf
chmod 644 /etc/slurm/cgroup.conf

echo "=== Creating directories ==="
mkdir -p /var/spool/slurmctld /var/spool/slurmd
chown slurm:slurm /var/spool/slurmctld /var/spool/slurmd
chmod 755 /var/spool/slurmctld /var/spool/slurmd

mkdir -p /cluster/logs/slurm
touch /cluster/logs/slurm/slurmctld.log /cluster/logs/slurm/slurmd.log
chown slurm:slurm /cluster/logs/slurm \
    /cluster/logs/slurm/slurmctld.log \
    /cluster/logs/slurm/slurmd.log
chmod 755 /cluster/logs/slurm
chmod 644 /cluster/logs/slurm/slurmctld.log /cluster/logs/slurm/slurmd.log

echo "=== Starting Slurm ==="
systemctl daemon-reload
if [ "$ROLE" = "controller" ]; then
    systemctl enable slurmctld slurmd
    systemctl start slurmctld slurmd
else
    systemctl enable slurmd
    systemctl start slurmd
fi

echo "=== Done ==="
if [ "$ROLE" = "controller" ]; then
    echo ""
    echo "Once all compute nodes are done, delete the munge key:"
    echo "  rm /home/${WITS_USER}/munge.key"
    echo ""
    echo "Then verify:"
    echo "  sinfo"
    echo "  srun -p brrr -N 4 --ntasks-per-node=1 --mpi=pmix hostname"
fi
