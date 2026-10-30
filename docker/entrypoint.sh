#!/bin/sh
set -eu

command_pid=
httpbin_pid=
cleanup() {
    if [ -n "$command_pid" ]; then
        kill "$command_pid" 2>/dev/null || true
        wait "$command_pid" 2>/dev/null || true
    fi
    if [ -n "$httpbin_pid" ]; then
        kill "$httpbin_pid" 2>/dev/null || true
        wait "$httpbin_pid" 2>/dev/null || true
    fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# Tests hard-code localhost:8000, so httpbin must share the test container.
/usr/bin/gunicorn --bind 127.0.0.1:8000 --workers 2 \
    --access-logfile - --error-logfile - httpbin:app &
httpbin_pid=$!

# Do not begin the suite until the HTTP fixture is actually ready.
python3 - <<'PY'
import time
import urllib.error
import urllib.request

opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
for _ in range(100):
    try:
        with opener.open("http://127.0.0.1:8000/get", timeout=1) as response:
            if response.status == 200:
                break
    except (OSError, urllib.error.URLError):
        pass
    time.sleep(0.1)
else:
    raise SystemExit("httpbin did not become ready on localhost:8000")
PY

"$@" <&0 &
command_pid=$!
status=0
wait "$command_pid" || status=$?
command_pid=
exit "$status"
