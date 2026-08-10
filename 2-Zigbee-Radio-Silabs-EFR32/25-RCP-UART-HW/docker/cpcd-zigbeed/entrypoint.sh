#!/bin/bash
set -e

echo "=== cpcd-zigbeed container starting ==="
echo "RCP endpoint: ${RCP_HOST}:${RCP_PORT}"
echo "cpcd instance: ${CPCD_INSTANCE}"
echo "Zigbeed port: ${ZIGBEED_PORT}"

# Create required directories
mkdir -p /dev/shm/cpcd/${CPCD_INSTANCE}
mkdir -p /var/log/supervisor
mkdir -p /var/log/cpcd
mkdir -p /var/lib/zigbeed

# Generate cpcd.conf from template
envsubst < /etc/cpcd/cpcd.conf.template > /etc/cpcd/cpcd.conf
echo "Generated /etc/cpcd/cpcd.conf:"
cat /etc/cpcd/cpcd.conf

# Wait for gateway to be reachable
echo "Waiting for RCP endpoint ${RCP_HOST}:${RCP_PORT}..."
timeout=60
while ! nc -z ${RCP_HOST} ${RCP_PORT} 2>/dev/null; do
    timeout=$((timeout - 1))
    if [ $timeout -le 0 ]; then
        echo "ERROR: Cannot reach ${RCP_HOST}:${RCP_PORT} after 60 seconds"
        exit 1
    fi
    sleep 1
done
echo "RCP endpoint reachable"

# Execute the main command
exec "$@"
