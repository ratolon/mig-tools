#!/usr/bin/env bash
set -euo pipefail

NODE_NAME=$(hostname)
GRES_CONF="/etc/slurm/gres.conf"
TMP_GRES="/tmp/gres.conf.$$"

echo "[INFO] Draining node ${NODE_NAME}..."
#scontrol update NodeName=${NODE_NAME} State=DRAIN Reason="MIG reconfig"

echo "[INFO] Waiting for jobs to finish..."
while squeue -w ${NODE_NAME} -h | grep -q .; do
    sleep 5
done

echo "[INFO] Detecting MIG configuration..."

nvidia-smi -L | awk -v node="${NODE_NAME}" '
match($0, /^[[:space:]]*MIG[[:space:]]+([0-9]+g\.[0-9]+gb)[[:space:]]+Device[[:space:]]+[0-9]+:/, m) {
    counts["a100_" m[1]]++
}
END {
    for (type in counts) {
        printf "NodeName=%s Name=gpu Type=%s Count=%d\n", node, type, counts[type]
    }
}
' > "${TMP_GRES}"

if [[ ! -s "${TMP_GRES}" ]]; then
    echo "[WARN] No MIG devices detected from nvidia-smi -L"
fi

echo "[INFO] Generated GRES:"
cat "${TMP_GRES}"

#cp "${TMP_GRES}" "${GRES_CONF}"

# echo "[INFO] Reconfiguring SLURM..."
#scontrol reconfigure

#echo "[INFO] Resuming node..."
#scontrol update NodeName=${NODE_NAME} State=RESUME

echo "[INFO] Done."
