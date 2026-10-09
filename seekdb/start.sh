#!/bin/bash

set -e

WAIT_FOR_CONFIG_FILE_ATTEMPTS=600
WAIT_FOR_PASSWORD_SET_ATTEMPTS=300
WAIT_FOR_SERVICE_READY_ATTEMPTS=300
WAIT_INTERVAL_SECONDS=1

CONFIG_FILE="/etc/seekdb/seekdb.cnf"
SEEKDB_BASE_DIR="/var/lib/seekdb"
SEEKDB_CONFIG_FILE="${SEEKDB_BASE_DIR}/etc/seekdb.data_version.bin"
INITIALIZED_FLAG="${SEEKDB_BASE_DIR}/.initialized"
OBSHELL_SOCK="${SEEKDB_BASE_DIR}/run/obshell.sock"

SEEKDB_PID=""
OBSHELL_STARTED=0
CLEANING_UP=0

# Set or append key=value in seekdb.cnf (line may be absent in newer packages)
seekdb_set_cnf() {
    local key="$1"
    local value="$2"
    if [ -f "$CONFIG_FILE" ] && grep -qE "^${key}=" "$CONFIG_FILE"; then
        sed -i "s|^${key}=.*|${key}=${value}|" "$CONFIG_FILE"
    else
        echo "${key}=${value}" >> "$CONFIG_FILE"
    fi
}

cleanup() {
    if [ "$CLEANING_UP" -eq 1 ]; then
        return
    fi
    CLEANING_UP=1

    if [ "$OBSHELL_STARTED" -eq 1 ]; then
        obshell agent stop --seekdb --base-dir="$SEEKDB_BASE_DIR" >/dev/null 2>&1 || true
        OBSHELL_STARTED=0
    fi

    if [ -n "$SEEKDB_PID" ] && kill -0 "$SEEKDB_PID" 2>/dev/null; then
        kill -TERM "$SEEKDB_PID" 2>/dev/null || true
        for _ in $(seq 1 15); do
            kill -0 "$SEEKDB_PID" 2>/dev/null || break
            sleep 1
        done
        if kill -0 "$SEEKDB_PID" 2>/dev/null; then
            kill -KILL "$SEEKDB_PID" 2>/dev/null || true
        fi
        wait "$SEEKDB_PID" 2>/dev/null || true
        SEEKDB_PID=""
    fi
}

on_signal() {
    echo "Received termination signal, shutting down..."
    cleanup
    exit 0
}

ensure_seekdb_alive() {
    if [ -z "$SEEKDB_PID" ] || ! kill -0 "$SEEKDB_PID" 2>/dev/null; then
        wait "$SEEKDB_PID" 2>/dev/null || true
        echo "Seekdb process exited unexpectedly."
        exit 1
    fi
}

password_api_succeeded() {
    local response="$1"
    # Require business success; curl exit 0 alone is not enough.
    echo "$response" | grep -Eq '"successful"[[:space:]]*:[[:space:]]*true'
}

if [ -n "$DATAFILE_SIZE" ]; then
    seekdb_set_cnf datafile_size "$DATAFILE_SIZE"
fi

if [ -n "$DATAFILE_NEXT" ]; then
    seekdb_set_cnf datafile_next "$DATAFILE_NEXT"
fi

if [ -n "$DATAFILE_MAXSIZE" ]; then
    seekdb_set_cnf datafile_maxsize "$DATAFILE_MAXSIZE"
fi

if [ -n "$CPU_COUNT" ]; then
    seekdb_set_cnf cpu_count "$CPU_COUNT"
fi

if [ -n "$MEMORY_LIMIT" ]; then
    seekdb_set_cnf memory_limit "$MEMORY_LIMIT"
fi

if [ -n "$LOG_DISK_SIZE" ]; then
    seekdb_set_cnf log_disk_size "$LOG_DISK_SIZE"
fi

trap on_signal TERM INT
trap cleanup EXIT

# Clear stale runtime files left by an unclean previous container stop so
# seekdb/obshell can start again against a persisted data directory.
mkdir -p "${SEEKDB_BASE_DIR}/run"
rm -f \
    "${SEEKDB_BASE_DIR}/run/daemon.pid" \
    "${SEEKDB_BASE_DIR}/run/daemon.sock" \
    "${SEEKDB_BASE_DIR}/run/obshell.pid" \
    "${SEEKDB_BASE_DIR}/run/obshell.sock" \
    "${SEEKDB_BASE_DIR}/run/seekdb.pid" \
    "${SEEKDB_BASE_DIR}/run/seekdb"

# seekdb_systemd_start now exec's seekdb --nodaemon (foreground). Run it in the
# background so initialization can continue, and keep its PID for supervision.
/usr/libexec/seekdb/scripts/seekdb_systemd_start 2>/dev/null &
SEEKDB_PID=$!

for i in $(seq 1 $WAIT_FOR_CONFIG_FILE_ATTEMPTS); do
    ensure_seekdb_alive
    if [ -f "$SEEKDB_CONFIG_FILE" ]; then
        echo "File '$SEEKDB_CONFIG_FILE' found on attempt #$i."
        break
    fi
    if [ "$i" -eq "$WAIT_FOR_CONFIG_FILE_ATTEMPTS" ]; then
        echo "Timeout waiting for '$SEEKDB_CONFIG_FILE'."
        exit 1
    fi
    if [ $((i % 10)) -eq 0 ]; then
        echo "seekdb is still not ready."
    fi
    sleep $WAIT_INTERVAL_SECONDS
done

obshell agent start --seekdb --base-dir="$SEEKDB_BASE_DIR"
OBSHELL_STARTED=1

if [ ! -f "$INITIALIZED_FLAG" ]; then
    PASSWORD_SET=0
    for i in $(seq 1 $WAIT_FOR_PASSWORD_SET_ATTEMPTS); do
        ensure_seekdb_alive
        RESPONSE=$(curl -sS -X PUT "http://127.0.0.1:2886/api/v1/seekdb/user/root/password" \
            -H "Content-Type: application/json" \
            -d "{\"password\":\"$ROOT_PASSWORD\"}" \
            --unix-socket "$OBSHELL_SOCK" 2>&1) || true
        if password_api_succeeded "$RESPONSE"; then
            echo "$RESPONSE"
            echo "Command succeeded on attempt #$i."
            PASSWORD_SET=1
            break
        fi
        echo "Command failed on attempt #$i (response: $RESPONSE). Retrying in $WAIT_INTERVAL_SECONDS seconds..."
        sleep $WAIT_INTERVAL_SECONDS
    done

    if [ "$PASSWORD_SET" -ne 1 ]; then
        echo "Failed to set root password via obshell API. Initialization aborted."
        exit 1
    fi

    # Init database and execute init scripts
    MYSQL_OPTS="-h127.0.0.1 -P2881 -uroot"
    if [ -n "$ROOT_PASSWORD" ]; then
        MYSQL_OPTS="$MYSQL_OPTS -p$ROOT_PASSWORD"
    fi

    if [ -n "$SEEKDB_DATABASE" ]; then
        mysql $MYSQL_OPTS -e "CREATE DATABASE IF NOT EXISTS \`$SEEKDB_DATABASE\`;"
        echo "Database $SEEKDB_DATABASE created."
        MYSQL_OPTS="$MYSQL_OPTS -D$SEEKDB_DATABASE"
    fi

    if [ -n "$INIT_SCRIPTS_PATH" ]; then
        echo "Executing initialization scripts from $INIT_SCRIPTS_PATH..."
        for sql_file in "$INIT_SCRIPTS_PATH"/*.sql; do
            if [ -f "$sql_file" ]; then
                echo "Executing $sql_file..."
                mysql $MYSQL_OPTS < "$sql_file"
                echo "Finished executing $sql_file."
            fi
        done
        echo "Initialization scripts execution complete."
    fi

    # Create the initialized flag only after successful password/init work.
    touch "$INITIALIZED_FLAG"
    echo "Initialization complete."
else
    echo "Already initialized. Skipping initialization."
fi

# Execute command passed to docker run if present
if [ $# -gt 0 ]; then
    MYSQL_OPTS="-h127.0.0.1 -P2881 -uroot"
    if [ -n "$ROOT_PASSWORD" ]; then
        MYSQL_OPTS="$MYSQL_OPTS -p$ROOT_PASSWORD"
    fi

    echo "Waiting for seekdb to be ready..."
    for i in $(seq 1 $WAIT_FOR_SERVICE_READY_ATTEMPTS); do
        ensure_seekdb_alive
        if mysql $MYSQL_OPTS -e "show databases" >/dev/null 2>&1; then
            echo "seekdb is ready."
            break
        fi
        if [ "$i" -eq "$WAIT_FOR_SERVICE_READY_ATTEMPTS" ]; then
            echo "Timeout waiting for seekdb to be ready."
            exit 1
        fi
        sleep $WAIT_INTERVAL_SECONDS
    done

    if [ -n "$SEEKDB_DATABASE" ]; then
        MYSQL_OPTS="$MYSQL_OPTS -D$SEEKDB_DATABASE"
    fi

    echo "Executing sql: $*"
    mysql $MYSQL_OPTS -e "$*"
    SQL_EXIT=$?
    cleanup
    trap - EXIT TERM INT
    exit $SQL_EXIT
fi

echo "Seekdb started"
echo "Start seekdb health check loop"

# Drop EXIT trap before wait so a normal seekdb exit does not force cleanup twice.
trap - EXIT
set +e
wait "$SEEKDB_PID"
SEEKDB_EXIT=$?
set -e

echo "Seekdb process exited with code ${SEEKDB_EXIT}. Shutting down companions."
if [ "$OBSHELL_STARTED" -eq 1 ]; then
    obshell agent stop --seekdb --base-dir="$SEEKDB_BASE_DIR" >/dev/null 2>&1 || true
    OBSHELL_STARTED=0
fi
exit 1
