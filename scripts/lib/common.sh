# shellcheck shell=bash
# Common helpers shared by every 1s script (server and macOS).
# Source it; do not execute it.

if [[ -n "${_ONES_COMMON_LOADED:-}" ]]; then return 0; fi
_ONES_COMMON_LOADED=1

if (( BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 4) )); then
  echo "Bash >= 4.4 is required (these scripts run on the Linux server or in CI)." >&2
  exit 1
fi

# Repository/release root (two levels above scripts/lib).
ONES_ROOT="${ONES_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"

# Server-side locations. Overridable for tests only.
ONES_ETC="${ONES_ETC:-/etc/1s}"
ONES_VAR="${ONES_VAR:-/var/lib/1s}"
ONES_OPT="${ONES_OPT:-/opt/1s}"
ONES_LOCK_DIR="${ONES_LOCK_DIR:-/run/lock}"
# Prefix for container names and compose project names.
ONES_PREFIX="${ONES_PREFIX:-1s}"

_ones_ts() { date -u '+%Y-%m-%dT%H:%M:%SZ'; }

log()  { printf '%s [INFO]  %s\n' "$(_ones_ts)" "$*" >&2; }
warn() { printf '%s [WARN]  %s\n' "$(_ones_ts)" "$*" >&2; }
err()  { printf '%s [ERROR] %s\n' "$(_ones_ts)" "$*" >&2; }
die()  { err "$*"; exit 1; }

require_root() {
  [[ "${EUID}" -eq 0 ]] || die "This command must run as root (use sudo)."
}

require_cmd() {
  local c
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || die "Required command not found: $c"
  done
}

is_true() {
  case "${1,,}" in 1|true|yes|on) return 0 ;; *) return 1 ;; esac
}

# with_lock NAME CMD...  -- serialise operations with flock.
with_lock() {
  local name="$1"; shift
  local file="${ONES_LOCK_DIR}/1s-${name}.lock"
  mkdir -p "${ONES_LOCK_DIR}"
  (
    flock -w 600 9 || die "Timed out waiting for lock ${file}"
    "$@"
  ) 9>"${file}"
}

# Atomically write stdin to FILE with MODE (default 0644).
atomic_write() {
  local file="$1" mode="${2:-0644}" dir tmp
  dir="$(dirname "${file}")"
  mkdir -p "${dir}"
  tmp="$(mktemp "${dir}/.$(basename "${file}").XXXXXX")"
  chmod "${mode}" "${tmp}"
  if ! cat >"${tmp}"; then rm -f "${tmp}"; return 1; fi
  mv -f "${tmp}" "${file}"
}

# ---------------------------------------------------------------------------
# Validation helpers
# ---------------------------------------------------------------------------

is_ipv4() {
  local ip="$1" o
  [[ "${ip}" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
  for o in "${BASH_REMATCH[@]:1}"; do
    [[ "${o}" =~ ^(0|[1-9][0-9]*)$ ]] || return 1
    (( 10#${o} <= 255 )) || return 1
  done
}

# Expand an IPv6 address to 8 lowercase, zero-padded groups separated by ':'.
# Prints nothing and returns 1 when invalid.
ipv6_expand() {
  local ip="${1,,}" head tail v4 g grp=() hg=() tg=() i n
  [[ "${ip}" =~ ^[0-9a-f:.]+$ ]] || return 1
  [[ "${ip}" == *:::* ]] && return 1
  # Embedded IPv4 in the last 32 bits.
  if [[ "${ip}" == *.* ]]; then
    v4="${ip##*:}"
    is_ipv4 "${v4}" || return 1
    local a b c d
    IFS=. read -r a b c d <<<"${v4}"
    ip="${ip%:*}:$(printf '%x' $(( (10#$a << 8) | 10#$b ))):$(printf '%x' $(( (10#$c << 8) | 10#$d )))"
  fi
  if [[ "${ip}" == *::* ]]; then
    head="${ip%%::*}"; tail="${ip#*::}"
    [[ "${tail}" == *::* ]] && return 1
    [[ -n "${head}" ]] && IFS=: read -r -a hg <<<"${head}"
    [[ -n "${tail}" ]] && IFS=: read -r -a tg <<<"${tail}"
    n=$(( 8 - ${#hg[@]} - ${#tg[@]} ))
    (( n >= 1 )) || return 1
    grp=("${hg[@]}")
    for ((i = 0; i < n; i++)); do grp+=("0"); done
    grp+=("${tg[@]}")
  else
    [[ "${ip}" == :* || "${ip}" == *: ]] && return 1
    IFS=: read -r -a grp <<<"${ip}"
  fi
  (( ${#grp[@]} == 8 )) || return 1
  local res=()
  for g in "${grp[@]}"; do
    [[ "${g}" =~ ^[0-9a-f]{1,4}$ ]] || return 1
    res+=("$(printf '%04x' "0x${g}")")
  done
  local IFS=:
  printf '%s\n' "${res[*]}"
}

is_ipv6() { ipv6_expand "$1" >/dev/null; }

# Compress an expanded/any IPv6 address to RFC 5952 canonical form.
ipv6_compress() {
  local full groups=() i best_start=-1 best_len=0 cur_start=-1 cur_len=0
  full="$(ipv6_expand "$1")" || return 1
  IFS=: read -r -a groups <<<"${full}"
  for ((i = 0; i < 8; i++)); do
    groups[i]="$(printf '%x' "0x${groups[i]}")"
    if [[ "${groups[i]}" == 0 ]]; then
      (( cur_start < 0 )) && cur_start=$i
      cur_len=$(( cur_len + 1 ))
      if (( cur_len > best_len )); then best_len=$cur_len; best_start=$cur_start; fi
    else
      cur_start=-1; cur_len=0
    fi
  done
  if (( best_len < 2 )); then
    local IFS=:; printf '%s\n' "${groups[*]}"; return 0
  fi
  local left=("${groups[@]:0:best_start}") right=("${groups[@]:best_start+best_len}") l r
  l="$(IFS=:; printf '%s' "${left[*]}")"
  r="$(IFS=:; printf '%s' "${right[*]}")"
  printf '%s::%s\n' "${l}" "${r}"
}

# Normalise an IPv4/IPv6 address or CIDR. Host bits are cleared and single
# addresses get no prefix. Prints the canonical form or returns 1.
normalize_cidr() {
  local input="$1" addr prefix
  if [[ "${input}" == */* ]]; then
    addr="${input%/*}"; prefix="${input##*/}"
    [[ "${prefix}" =~ ^(0|[1-9][0-9]{0,2})$ ]] || return 1
  else
    addr="${input}"; prefix=""
  fi
  if is_ipv4 "${addr}"; then
    [[ -z "${prefix}" ]] && prefix=32
    (( prefix <= 32 )) || return 1
    local a b c d n mask
    IFS=. read -r a b c d <<<"${addr}"
    n=$(( (10#$a << 24) | (10#$b << 16) | (10#$c << 8) | 10#$d ))
    if (( prefix == 0 )); then mask=0; else mask=$(( (0xFFFFFFFF << (32 - prefix)) & 0xFFFFFFFF )); fi
    n=$(( n & mask ))
    addr="$(( (n >> 24) & 255 )).$(( (n >> 16) & 255 )).$(( (n >> 8) & 255 )).$(( n & 255 ))"
    if (( prefix == 32 )); then printf '%s\n' "${addr}"; else printf '%s/%s\n' "${addr}" "${prefix}"; fi
    return 0
  fi
  local full groups=() i bits keep
  full="$(ipv6_expand "${addr}")" || return 1
  [[ -z "${prefix}" ]] && prefix=128
  (( prefix <= 128 )) || return 1
  IFS=: read -r -a groups <<<"${full}"
  for ((i = 0; i < 8; i++)); do
    bits=$(( prefix - i * 16 ))
    if (( bits >= 16 )); then continue
    elif (( bits <= 0 )); then groups[i]=0000
    else
      keep=$(( (0xFFFF << (16 - bits)) & 0xFFFF ))
      groups[i]="$(printf '%04x' $(( 0x${groups[i]} & keep )))"
    fi
  done
  addr="$(ipv6_compress "$(IFS=:; printf '%s' "${groups[*]}")")"
  if (( prefix == 128 )); then printf '%s\n' "${addr}"; else printf '%s/%s\n' "${addr}" "${prefix}"; fi
}

is_cidr() { normalize_cidr "$1" >/dev/null; }

is_domain() {
  local d="$1"
  (( ${#d} <= 253 )) || return 1
  [[ "${d}" =~ ^([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$ ]]
}

is_port() {
  [[ "$1" =~ ^[1-9][0-9]{0,4}$ ]] && (( 10#$1 <= 65535 ))
}

is_uint() { [[ "$1" =~ ^(0|[1-9][0-9]*)$ ]]; }

is_email() { [[ "$1" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]]; }

# ---------------------------------------------------------------------------
# dotenv handling (never `source` configuration files: they are data)
# ---------------------------------------------------------------------------

# env_load FILE -- assign KEY=VALUE lines to shell variables (no expansion).
env_load() {
  local file="$1" line key value
  [[ -r "${file}" ]] || return 0
  while IFS= read -r line || [[ -n "${line}" ]]; do
    line="${line%$'\r'}"
    [[ "${line}" =~ ^[[:space:]]*(#|$) ]] && continue
    [[ "${line}" =~ ^[[:space:]]*(export[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]] || {
      warn "Ignoring malformed line in ${file}"; continue; }
    key="${BASH_REMATCH[2]}"; value="${BASH_REMATCH[3]}"
    if [[ "${value}" =~ ^\"(.*)\"[[:space:]]*$ ]]; then value="${BASH_REMATCH[1]}"
    elif [[ "${value}" =~ ^\'(.*)\'[[:space:]]*$ ]]; then value="${BASH_REMATCH[1]}"
    else value="${value%%[[:space:]]#*}"; value="${value%"${value##*[![:space:]]}"}"
    fi
    printf -v "${key}" '%s' "${value}"
    export "${key?}"
  done <"${file}"
}

# env_get FILE KEY -- print the value of KEY from FILE (empty when missing).
env_get() {
  local file="$1" want="$2"
  ( unset "${want}"; env_load "${file}"; printf '%s' "${!want:-}" )
}

# Quote a value for a dotenv file read by both env_load and docker compose.
env_quote() {
  local v="$1"
  if [[ "${v}" =~ ^[A-Za-z0-9_./:@,+=-]*$ ]]; then printf '%s' "${v}"
  elif [[ "${v}" != *"'"* ]]; then printf "'%s'" "${v}"
  else printf '"%s"' "${v}"
  fi
}

# Random secrets ------------------------------------------------------------
gen_secret() {
  # 32 random bytes, base64url without padding (43 chars).
  openssl rand 32 | base64 | tr '+/' '-_' | tr -d '=\n'
}

# hmac_hex KEY MESSAGE -- HMAC-SHA256 hex digest. The key is passed through the
# environment (not argv, which is world-readable in /proc). Never log results.
hmac_hex() {
  _ONES_HMAC_KEY="$1" _ONES_HMAC_MSG="$2" python3 -c '
import hashlib, hmac, os
print(hmac.new(os.environ["_ONES_HMAC_KEY"].encode(), os.environ["_ONES_HMAC_MSG"].encode(), hashlib.sha256).hexdigest())'
}
