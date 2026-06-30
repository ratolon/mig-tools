#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 2 ]]; then
    echo "Usage: $0 /path/to/cryosparcw worker-hostname"
    exit 1
fi

CRYOSPARCW_BIN="$1"
WORKER_HOSTNAME="$2"
CRYOSPARC_MASTER_HOSTNAME="$3"
CRYOSPARC_MASTER_PORT="$4"
CRYOSPARC_SSHSTR="$5"

if [[ ! -x "$CRYOSPARCW_BIN" ]]; then
    echo "[ERROR] cryosparcw executable not found or not executable: $CRYOSPARCW_BIN"
    exit 1
fi

CMD=("$CRYOSPARCW_BIN" connect --worker "$WORKER_HOSTNAME" --update)

if [[ -n "$CRYOSPARC_MASTER_HOSTNAME" ]]; then
    CMD+=(--master "$CRYOSPARC_MASTER_HOSTNAME")
fi

if [[ -n "$CRYOSPARC_MASTER_PORT" ]]; then
    CMD+=(--master "$CRYOSPARC_MASTER_PORT")
fi

CMD+=(--nossd )
CMD+=(--sshstr "$CRYOSPARC_SSHSTR")

echo "[INFO] Updating managed worker configuration for $WORKER_HOSTNAME..."
"${CMD[@]}"
echo "[INFO] cryoSPARC worker configuration updated successfully."