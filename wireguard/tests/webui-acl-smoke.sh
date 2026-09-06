#!/usr/bin/env bash
# =============================================================================
# Smoke test for the optional web interface (web_interface: true).
#
# The web UI serves private-key-bearing QR codes and client configs, so it must
# be reachable ONLY through the Home Assistant Ingress proxy (172.30.32.2). This
# test guards two things that would silently break that boundary:
#   1. the add-on installs an httpd to serve the UI — stock busybox has no httpd
#      applet, so the Dockerfile must pull in busybox-extras;
#   2. rootfs/etc/httpd.conf enforces the Ingress-only source-IP ACL: the proxy
#      address is served, every other source is not.
#
# Both are checked against what the add-on itself declares. The httpd package is
# read out of the Dockerfile rather than installed by name here, so dropping or
# renaming that dependency fails this test instead of shipping a web UI that
# cannot start. The ACL is exercised as it ships, from a real 172.30.32.2 source
# address — no stand-in config, no stand-in client.
#
# Needs Docker, and CAP_NET_ADMIN in the test container to take the Ingress
# proxy address. Runnable locally: bash webui-acl-smoke.sh
# Set WEBUI_SMOKE_IMAGE=<tag> to run the same assertions against an already
# built add-on image — the strongest form of this test, but it needs the full
# add-on build (Go toolchain + git.zx2c4.com), which is the release pipeline's
# job, not this test's.
# =============================================================================
set -euo pipefail

addon_dir="$(cd "$(dirname "$0")/.." && pwd)"
conf="${addon_dir}/rootfs/etc/httpd.conf"
image="${WEBUI_SMOKE_IMAGE:-}"

test -f "${conf}" || { echo "FAIL: ${conf} not found"; exit 1; }

# The ACL is the security boundary, so assert the exact rules and their order:
# busybox httpd evaluates them top-down, so an allow rule that lands after the
# catch-all deny is dead. Anything else here is a change that must be reviewed.
if [[ "$(grep -E '^[ADI]:' "${conf}")" != "$(printf 'A:172.30.32.2\nD:*')" ]]; then
    echo "FAIL: ${conf} must contain exactly 'A:172.30.32.2' then 'D:*'"
    exit 1
fi
echo "OK: httpd.conf declares the Ingress-only ACL"

if [[ -z "${image}" ]]; then
    base="$(grep -m1 -E '^\s*amd64:' "${addon_dir}/build.yaml" | awk '{print $2}')"
    test -n "${base}" || { echo "FAIL: could not read amd64 base from build.yaml"; exit 1; }

    # Take the httpd package straight from the add-on's Dockerfile, pin and all.
    # This is what makes the check below meaningful: an unconditional
    # `apk add busybox-extras` here would keep passing after the Dockerfile
    # stopped installing it.
    httpd_pkg="$(grep -m1 -oE 'busybox-extras(=[^ \\]+)?' "${addon_dir}/Dockerfile" || true)"
    test -n "${httpd_pkg}" || {
        echo "FAIL: wireguard/Dockerfile no longer installs busybox-extras, so"
        echo "      the add-on image has no httpd applet and the web UI is dead."
        exit 1
    }
    echo "Dockerfile httpd package: ${httpd_pkg}"

    image="addon-wireguard:webui-smoke"
    docker build -q -t "${image}" -f - "${addon_dir}" > /dev/null << EOF
FROM ${base}
RUN apk add --no-cache ${httpd_pkg}
COPY rootfs/etc/httpd.conf /etc/httpd.conf
EOF
fi
echo "Image under test: ${image}"

# MSYS_NO_PATHCONV keeps Git Bash on Windows from rewriting the in-container
# paths below into Windows ones; it is ignored elsewhere. Scoped to this command
# because the build above does want its context path translated.
MSYS_NO_PATHCONV=1 \
docker run --rm --cap-add=NET_ADMIN --entrypoint /bin/bash "${image}" -c '
    set -eu

    # Nothing is installed here on purpose: the packages the add-on declares
    # must be what provides this.
    command -v httpd >/dev/null || {
        echo "FAIL: httpd missing — busybox-extras did not provide the applet"
        exit 1
    }
    echo "OK: httpd present"

    mkdir -p /tmp/www
    echo "PRIVATE-KEY-MATERIAL" > /tmp/www/index.html

    # Take the Supervisor Ingress proxy address, so the allowed source is
    # exercised for real rather than stood in for by a local-only test rule.
    ip addr add 172.30.32.2/32 dev lo || {
        echo "FAIL: could not add the Ingress proxy address (needs NET_ADMIN)"
        exit 1
    }

    # One server, serving the ACL exactly as it ships.
    httpd -f -p 8099 -c /etc/httpd.conf -h /tmp/www &
    ready=""
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        # Any HTTP status means it is listening; curl only fails to connect.
        if curl -s -o /dev/null http://127.0.0.1:8099/; then ready="yes"; break; fi
        sleep 1
    done
    [ -n "${ready}" ] || { echo "FAIL: httpd did not start"; exit 1; }

    # 1) The Ingress proxy is served.
    code=$(curl -s -o /dev/null -w "%{http_code}" http://172.30.32.2:8099/)
    [ "${code}" = "200" ] || {
        echo "FAIL: expected 200 for the Ingress proxy, got ${code}"
        exit 1
    }
    echo "OK: Ingress proxy served (200)"

    # 2) Every other source is denied by that same server and config.
    code=$(curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:8099/)
    [ "${code}" = "403" ] || {
        echo "FAIL: expected 403 for non-Ingress client, got ${code}"
        exit 1
    }
    echo "OK: non-Ingress client denied (403)"
'
echo "Web UI ACL smoke test passed."
