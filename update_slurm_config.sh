#!/usr/bin/env bash
set -euo pipefail

NODE_NAME=$(hostname)
GRES_CONF="/etc/slurm/gres.conf"
TMP_GRES="/tmp/gres.conf.$$"
TMP_COUNTS="/tmp/mig-counts.$$"
TMP_SLURM_SNIPPET="/tmp/slurm-node-gres.$$"

cleanup() {
    rm -f "${TMP_COUNTS}" "${TMP_SLURM_SNIPPET}"
}
trap cleanup EXIT

echo "[INFO] Draining node ${NODE_NAME}..."
#scontrol update NodeName=${NODE_NAME} State=DRAIN Reason="MIG reconfig"

echo "[INFO] Waiting for jobs to finish..."
while squeue -w ${NODE_NAME} -h | grep -q .; do
    sleep 5
done

echo "[INFO] Detecting MIG configuration..."

nvidia-smi -L | awk '
match($0, /^[[:space:]]*MIG[[:space:]]+([0-9]+g\.[0-9]+gb)[[:space:]]+Device[[:space:]]+[0-9]+:/, m) {
    counts[m[1]]++
}
END {
    for (type in counts) {
        printf "%s|%d\n", type, counts[type]
    }
}
' > "${TMP_COUNTS}"

{
    echo "AutoDetect=nvml"
} > "${TMP_GRES}"

if [[ -s "${TMP_COUNTS}" ]]; then
    awk -F'|' -v node="${NODE_NAME}" '
    BEGIN {
        printf "NodeName=%s Gres=", node
    }
    {
        if (NR > 1) {
            printf ","
        }
        printf "gpu:nvidia_a100_80gb_pcie_%s:%s", $1, $2
    }
    END {
        printf "\n"
    }
    ' "${TMP_COUNTS}" > "${TMP_SLURM_SNIPPET}"
fi

if [[ ! -s "${TMP_COUNTS}" ]]; then
    echo "[WARN] No MIG devices detected from nvidia-smi -L"
    exit 1
fi

echo "[INFO] Generated GRES:"
cat "${TMP_GRES}"

echo "[INFO] Suggested slurm.conf Gres line for this node:"
cat "${TMP_SLURM_SNIPPET}"

# Update gres.conf
echo "[INFO] Updating gres.conf..."
if ! sudo cp "${TMP_GRES}" "${GRES_CONF}"; then
    echo "[ERROR] Failed to write ${GRES_CONF}. Check permissions."
    exit 1
fi
echo "[INFO] gres.conf updated successfully."

# Update slurm.conf NodeName line
SLURM_CONF="/etc/slurm/slurm.conf"
if [[ ! -f "${SLURM_CONF}" ]]; then
    echo "[ERROR] slurm.conf not found at ${SLURM_CONF}"
    exit 1
fi

echo "[INFO] Updating slurm.conf NodeName line..."
GRES_LINE=$(cat "${TMP_SLURM_SNIPPET}" | grep -oP 'Gres=.*')

# Create backup
sudo cp "${SLURM_CONF}" "${SLURM_CONF}.bak.$(date +%s)"

# Update only the Gres= part in slurm.conf
if ! sudo sed -i "s|Gres=[^ ]*|${GRES_LINE}|" "${SLURM_CONF}"; then
    echo "[ERROR] Failed to update slurm.conf"
    exit 1
fi
echo "[INFO] slurm.conf updated successfully."

echo "[INFO] Reconfiguring SLURM..."
if ! sudo scontrol reconfigure; then
    echo "[ERROR] Failed to reconfigure SLURM with scontrol reconfigure"
    exit 1
fi
echo "[INFO] SLURM reconfiguration complete."

echo "[INFO] Resuming node..."
if ! sudo scontrol update NodeName="${NODE_NAME}" State=RESUME; then
    echo "[WARN] Could not resume node (it may already be UP)"
fi

echo "[INFO] Done successfully!"
