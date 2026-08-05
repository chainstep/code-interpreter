#!/bin/bash
set -euo pipefail

fd_limit="${SANDBOX_RUNNER_FD_LIVENESS_LIMIT:-40000}"
timeout_seconds="${SANDBOX_RUNNER_HEALTHCHECK_TIMEOUT_SECONDS:-5}"
port="${PORT:-2000}"
url="${SANDBOX_RUNNER_HEALTHCHECK_URL:-http://127.0.0.1:${port}/api/v2/runtimes}"

case "$fd_limit" in
    ''|*[!0-9]*)
        echo "invalid SANDBOX_RUNNER_FD_LIVENESS_LIMIT: $fd_limit" >&2
        exit 2
        ;;
esac

if [ "$fd_limit" -gt 0 ]; then
    fd_count=$(find /proc/1/fd -mindepth 1 -maxdepth 1 2>/dev/null | wc -l | tr -d '[:space:]')
    if [ "$fd_count" -ge "$fd_limit" ]; then
        echo "sandbox-runner unhealthy: pid 1 has ${fd_count} open fds, limit is ${fd_limit}" >&2
        exit 1
    fi
fi

if command -v curl >/dev/null 2>&1; then
    curl -fsS --max-time "$timeout_seconds" "$url" >/dev/null
elif command -v bun >/dev/null 2>&1; then
    timeout "$timeout_seconds" bun -e "
        const response = await fetch('${url}');
        process.exit(response.ok ? 0 : 1);
    " >/dev/null
else
    echo "sandbox-runner healthcheck has no HTTP client (curl or bun) available" >&2
    exit 2
fi
