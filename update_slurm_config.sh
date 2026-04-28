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

declare -A COUNTS

current_gpu=""

while read -r line; do
    if [[ "$line" =~ ^GPU\ ([0-9]+): ]]; then
        echo "Reading MIGs in GPU ${BASH_REMATCH[1]}"
        current_gpu="${BASH_REMATCH[1]}"
    fi

    if [[ "$line" =~ MIG\ ([0-9]+g\.[0-9]+gb)\ Device ]]; then
        mig="${BASH_REMATCH[1]}"
        key="a100_${mig}"
        ((COUNTS[$key]++))
    fi
done < <(nvidia-smi -L)

> "${TMP_GRES}"

for type in "${!COUNTS[@]}"; do
    count="${COUNTS[$type]}"
    echo "NodeName=${NODE_NAME} Name=gpu Type=${type} Count=${count}" >> "${TMP_GRES}"
done

echo "[INFO] Generated GRES:"
cat "${TMP_GRES}"

#cp "${TMP_GRES}" "${GRES_CONF}"

# echo "[INFO] Reconfiguring SLURM..."
#scontrol reconfigure

#echo "[INFO] Resuming node..."
#scontrol update NodeName=${NODE_NAME} State=RESUME

echo "[INFO] Done."
