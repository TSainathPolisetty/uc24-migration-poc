#!/bin/sh
set -e

PAYLOAD_DIR="$SNAP_DATA/payloads"
PAYLOAD_FILE="$PAYLOAD_DIR/uc24.img"
CONFIG_FILE="$SNAP_DATA/migration.conf"

mkdir -p "$PAYLOAD_DIR"

# Copy payload only if missing
if [ ! -f "$PAYLOAD_FILE" ]; then
    echo "[wrapper] First run: copying payload..."
    cp -v "$SNAP/payloads/uc24.img" "$PAYLOAD_FILE"
else
    echo "[wrapper] Payload already present, skipping copy."
fi

# Write config (idempotent overwrite OK)
cat > "$CONFIG_FILE" <<EOF
MIGRATE_CORE=true
IMAGE=$PAYLOAD_FILE
NETWORK_REQUIRED=true
EOF

echo "[wrapper] Config written to $CONFIG_FILE"

# Done – nothing else to exec since migration-agent runs outside the snap
sleep infinity
