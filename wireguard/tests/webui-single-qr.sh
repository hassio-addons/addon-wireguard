#!/usr/bin/env bash
# =============================================================================
# The web UI shows one peer's QR code at a time (CSS-only tabs, no JavaScript).
# Every way that breaks breaks silently — the page still renders, just with all
# the cards showing again, or with none of them showing. So rather than assert
# that the generator *looks* a certain way, this runs the generator's own web
# interface block over fake peers and asserts on the page it produces:
#
#   * exactly one card is preselected, and it is the first card that actually
#     made it onto the page — a peer skipped for a missing QR code must not
#     consume the preselection and leave the page blank on load;
#   * every card is preceded by its radio and label, in that order, since
#     "input:checked + label + .peer" is what reveals the selected one;
#   * the stylesheet still hides .peer by default and reveals only the checked
#     one — dropping either rule puts every QR code back on screen at once.
#
# The block is lifted out of the s6 init script and run against stub bashio
# functions, so this needs no container and no bashio.
#
# Needs a filesystem that honours chmod, because the block installs its tree
# 0700 — so a real Linux/macOS shell, not Git Bash on Windows.
# Runnable locally: bash webui-single-qr.sh
# =============================================================================
set -euo pipefail

addon_dir="$(cd "$(dirname "$0")/.." && pwd)"
gen="${addon_dir}/rootfs/etc/s6-overlay/s6-rc.d/init-wireguard/run"

test -f "${gen}" || { echo "FAIL: ${gen} not found"; exit 1; }

work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT

# The block to exercise: from where the web tree is defined to the end of the
# script. Anchored on the assignment rather than a line number so the test
# follows the code instead of drifting off it.
start="$(grep -n '^www_dir="/var/lib/wireguard/www"$' "${gen}" | cut -d: -f1)"
if [[ -z "${start}" ]]; then
    echo "FAIL: could not find the web interface block in ${gen}."
    echo "      It is anchored on the line 'www_dir=\"/var/lib/wireguard/www\"';"
    echo "      if that assignment moved or was reformatted, re-anchor this test."
    exit 1
fi
tail -n "+${start}" "${gen}" > "${work}/block.sh"

# Three peers, the FIRST one missing its QR code. That ordering is the point:
# it must be skipped without consuming the preselection, or the page loads with
# nothing selected and no QR code on screen.
mkdir -p "${work}/ssl/alpha" "${work}/ssl/bravo" "${work}/ssl/charlie"
for p in alpha bravo charlie; do
    echo "[Interface]" > "${work}/ssl/${p}/client.conf"
done
printf 'not-a-real-png' > "${work}/ssl/bravo/qrcode.png"
printf 'not-a-real-png' > "${work}/ssl/charlie/qrcode.png"

# Stub bashio and run the block. /ssl/wireguard and /var/lib are rewritten to
# the temp tree; nothing else in the block is touched.
sed -e "s#/var/lib/wireguard/www#${work}/www#" \
    -e "s#/ssl/wireguard#${work}/ssl#" \
    "${work}/block.sh" > "${work}/run.sh"

bashio_stub="
bashio::config.true() { [[ \"\$1\" == 'web_interface' ]]; }
bashio::config() { case \"\$1\" in
    'peers|keys') printf '0\n1\n2\n' ;;
    'peers[0].name') echo alpha ;;
    'peers[1].name') echo bravo ;;
    'peers[2].name') echo charlie ;;
esac; }
bashio::fs.file_exists() { [[ -f \"\$1\" ]]; }
bashio::var.is_empty() { [[ -z \"\$1\" ]]; }
bashio::log.info() { :; }
bashio::log.warning() { :; }
bashio::exit.nok() { echo \"generator aborted: \$*\" >&2; exit 1; }
"

if ! bash -c "${bashio_stub}$(cat "${work}/run.sh")"; then
    echo "FAIL: the web interface block did not run to completion"
    exit 1
fi

page="${work}/www/index.html"
test -f "${page}" || { echo "FAIL: no index.html was generated"; exit 1; }

# 1. Exactly one preselected card, and it is the first one on the page.
n_checked="$(grep -c '<input[^>]* checked>' "${page}" || true)"
if [[ "${n_checked}" != "1" ]]; then
    echo "FAIL: ${n_checked} peers are preselected, expected exactly 1"
    echo "      (0 means the page loads with no QR code visible)"
    exit 1
fi
# alpha has no QR code, so bravo and charlie are the cards, and bravo — the
# first card that made it onto the page, not the first peer configured — is
# the one preselected.
if ! grep -q 'id="peer-bravo" checked>' "${page}"; then
    echo "FAIL: the preselected card is not the first one on the page"
    grep -n '<input' "${page}"
    exit 1
fi
if grep -q 'peer-alpha' "${page}"; then
    echo "FAIL: a peer with no QR code still got a card"
    exit 1
fi

# 2. Every card is preceded by its radio then its label, which is the adjacency
#    "input:checked + label + .peer" selects on.
shape="$(grep -oE '<(input|label|div class="peer")' "${page}" | tr '\n' ' ')"
expected='<input <label <div class="peer" <input <label <div class="peer" '
if [[ "${shape}" != "${expected}" ]]; then
    echo "FAIL: cards are not emitted as input, label, div"
    echo "      got:      ${shape}"
    echo "      expected: ${expected}"
    exit 1
fi

# 3. The two rules that make it one-at-a-time rather than all-at-once.
if ! grep -qE '^\.peer\{display:none;' "${page}"; then
    echo "FAIL: .peer is not hidden by default, every QR code would show at once"
    exit 1
fi
if ! grep -qF 'input:checked + label + .peer{display:block}' "${page}"; then
    echo "FAIL: no rule reveals the selected peer card, the page would be blank"
    exit 1
fi

echo "PASS: web UI shows exactly one QR code at a time"
