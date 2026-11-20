#!/usr/bin/env bash
#
# Multi-version upgrade test for erlfdb.
#
# Validates that erlfdb compiled against an older FDB version can connect
# to both old and new servers via the FDB multi-version client mechanism.
#
# Environment variables (set by CI):
#   FDB_OLD - old FDB version (e.g. "7.2.2")
#   FDB_NEW - new FDB version (e.g. "7.3.62")
#
# Prerequisites: FDB .deb packages for both versions must be downloaded
# in the current directory before running this script.
#
set -euo pipefail

: "${FDB_OLD:?FDB_OLD must be set (e.g. 7.2.2)}"
: "${FDB_NEW:?FDB_NEW must be set (e.g. 7.3.62)}"

# Derive the compile-time API version from the old FDB major.minor.
# FDB 7.2.x -> API 720, 7.3.x -> API 730, etc.
FDB_OLD_MAJOR="${FDB_OLD%%.*}"
FDB_OLD_MINOR="${FDB_OLD#*.}"; FDB_OLD_MINOR="${FDB_OLD_MINOR%%.*}"
COMPILE_API_VERSION="${FDB_OLD_MAJOR}${FDB_OLD_MINOR}0"
PORT=4500
MACHINE_ID="erlfdbmvtest"
TEST_DIR="/tmp/fdb-upgrade-test"
DATA_DIR="${TEST_DIR}/data"
LOG_DIR="${TEST_DIR}/logs"
CLUSTER_FILE="${TEST_DIR}/fdb.cluster"
MV_DIR="/opt/fdb-multiversion"
FDB_NEW_DIR="/opt/fdb-${FDB_NEW}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

cleanup() {
    echo "=== Cleanup ==="
    kill "${FDB_PID:-}" 2>/dev/null || true
    wait "${FDB_PID:-}" 2>/dev/null || true
    rm -rf "${TEST_DIR}"
}
trap cleanup EXIT

echo "=== Step 1: Install FDB ${FDB_OLD} (system version) ==="
sudo dpkg -i "foundationdb-clients_${FDB_OLD}-1_amd64.deb"
sudo dpkg -i "foundationdb-server_${FDB_OLD}-1_amd64.deb"
# Stop the auto-started fdbmonitor; we manage fdbserver directly
sudo systemctl stop foundationdb 2>/dev/null || sudo service foundationdb stop 2>/dev/null || true

echo "=== Step 2: Extract FDB ${FDB_NEW} to ${FDB_NEW_DIR} ==="
sudo mkdir -p "${FDB_NEW_DIR}"
sudo dpkg-deb -x "foundationdb-clients_${FDB_NEW}-1_amd64.deb" "${FDB_NEW_DIR}"
sudo dpkg-deb -x "foundationdb-server_${FDB_NEW}-1_amd64.deb" "${FDB_NEW_DIR}"

echo "=== Step 3: Set up multiversion client directory ==="
sudo mkdir -p "${MV_DIR}"
sudo cp /usr/lib/libfdb_c.so "${MV_DIR}/libfdb_c_${FDB_OLD}.so"
sudo cp "${FDB_NEW_DIR}/usr/lib/libfdb_c.so" "${MV_DIR}/libfdb_c_${FDB_NEW}.so"
ls -la "${MV_DIR}/"

echo "=== Step 4: Compile erlfdb against FDB ${FDB_OLD} ==="
cd "${PROJECT_DIR}"
rm -f priv/erlfdb_nif.so c_src/*.o c_src/*.d
ERLFDB_INCLUDE_DIR=/usr/include \
ERLFDB_COMPILE_API_VERSION="${COMPILE_API_VERSION}" \
    rebar3 compile

echo "=== Step 5: Start fdbserver ${FDB_OLD} ==="
mkdir -p "${DATA_DIR}" "${LOG_DIR}"
echo "erlfdbmvtest:erlfdbmvtest@127.0.0.1:${PORT}" > "${CLUSTER_FILE}"

# Without --machine-id, fdbserver reads its machine ID from POSIX shared
# memory. The fdbserver started by the package in Step 1 creates that segment,
# and fdbserver 8.0.1 fails to read the segment that 7.3.62 writes: it exits
# with "Could not locate shared memory - 'machineId'" (see
# apple/foundationdb#1074). The CT harness in erlfdb_util also passes -i.
/usr/sbin/fdbserver \
    -p "127.0.0.1:${PORT}" \
    -C "${CLUSTER_FILE}" \
    -d "${DATA_DIR}" \
    -L "${LOG_DIR}" \
    --machine-id "${MACHINE_ID}" &
FDB_PID=$!
echo "fdbserver ${FDB_OLD} started (PID ${FDB_PID})"
sleep 3

echo "=== Step 6: Initialize database ==="
/usr/bin/fdbcli -C "${CLUSTER_FILE}" --exec "configure new single ssd"
sleep 2

echo "=== Step 7: Pre-upgrade verification ==="
timeout 120 escript test/multiversion/verify_fdb.escript "${CLUSTER_FILE}" pre_upgrade "${MV_DIR}" "${COMPILE_API_VERSION}"

echo "=== Step 8: Stop fdbserver ${FDB_OLD} ==="
kill "${FDB_PID}"
wait "${FDB_PID}" 2>/dev/null || true
unset FDB_PID
sleep 2

echo "=== Step 9: Start fdbserver ${FDB_NEW} ==="
"${FDB_NEW_DIR}/usr/sbin/fdbserver" \
    -p "127.0.0.1:${PORT}" \
    -C "${CLUSTER_FILE}" \
    -d "${DATA_DIR}" \
    -L "${LOG_DIR}" \
    --machine-id "${MACHINE_ID}" &
FDB_PID=$!
echo "fdbserver ${FDB_NEW} started (PID ${FDB_PID})"
sleep 5
if ! kill -0 "${FDB_PID}" 2>/dev/null; then
    echo "ERROR: fdbserver ${FDB_NEW} exited during startup"
    exit 1
fi

echo "=== Step 10: Post-upgrade verification ==="
# erlfdb retries forever when no server is reachable; bound the wait.
timeout 120 escript test/multiversion/verify_fdb.escript "${CLUSTER_FILE}" post_upgrade "${MV_DIR}" "${COMPILE_API_VERSION}"

echo ""
echo "=== Multi-version upgrade test PASSED ==="
