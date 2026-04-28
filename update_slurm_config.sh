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
fi

echo "[INFO] Generated GRES:"
cat "${TMP_GRES}"

if [[ -s "${TMP_SLURM_SNIPPET}" ]]; then
    echo "[INFO] Suggested slurm.conf Gres line for this node:"
    cat "${TMP_SLURM_SNIPPET}"
else
    echo "[WARN] Could not build a slurm.conf Gres line from detected MIG devices"
fi

#cp "${TMP_GRES}" "${GRES_CONF}"

# echo "[INFO] Reconfiguring SLURM..."
#scontrol reconfigure

#echo "[INFO] Resuming node..."
#scontrol update NodeName=${NODE_NAME} State=RESUME

echo "[INFO] Done."
