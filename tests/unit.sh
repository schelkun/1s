#!/usr/bin/env bash
# Unit tests (no Docker daemon needed). Run on Linux with bash >= 4.4,
# openssl, python3, git:   tests/unit.sh
set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${TESTS_DIR}/.." && pwd)"
# shellcheck source=tests/lib.sh
source "${TESTS_DIR}/lib.sh"

TMP="$(mktemp -d)"
trap 'rm -rf -- "${TMP}"' EXIT
export ONES_ETC="${TMP}/etc" ONES_VAR="${TMP}/var" ONES_OPT="${TMP}/opt" ONES_LOCK_DIR="${TMP}/lock"
export PATH="${TESTS_DIR}/fixtures/bin:${PATH}"

# shellcheck source=scripts/lib/nginx.sh
source "${REPO}/scripts/lib/nginx.sh"

load_fixture() { env_load "${TESTS_DIR}/fixtures/test.env"; config_apply_defaults; }

echo "== address validation and normalisation"
assert_ok   "ipv4 valid"            is_ipv4 198.51.100.10
assert_fail "ipv4 octet > 255"      is_ipv4 198.51.100.256
assert_fail "ipv4 leading zero"     is_ipv4 198.051.100.1
assert_fail "ipv4 too short"        is_ipv4 10.0.0
assert_ok   "ipv6 compressed"       is_ipv6 2001:db8::1
assert_ok   "ipv6 full"             is_ipv6 2001:0db8:0000:0000:0000:0000:0000:0001
assert_ok   "ipv6 v4-mapped"        is_ipv6 ::ffff:192.0.2.1
assert_fail "ipv6 double ::"        is_ipv6 2001::db8::1
assert_fail "ipv6 bad group"        is_ipv6 2001:db8::12345
assert_fail "ipv6 garbage"          is_ipv6 'fe80::1;id'
assert_eq   "ipv6 compress"         "2001:db8::1" "$(ipv6_compress 2001:0db8:0000:0000:0000:0000:0000:0001)"
assert_eq   "ipv6 compress longest" "2001:0:0:1::1" "$(ipv6_compress 2001:0:0:1:0:0:0:1)"
assert_eq   "cidr4 host bits"       "198.51.100.0/24" "$(normalize_cidr 198.51.100.77/24)"
assert_eq   "cidr4 /32 is host"     "198.51.100.7" "$(normalize_cidr 198.51.100.7/32)"
assert_eq   "cidr4 /0"              "0.0.0.0/0" "$(normalize_cidr 10.1.2.3/0)"
assert_eq   "cidr6 host bits"       "2001:db8::/32" "$(normalize_cidr 2001:db8:abcd::1/32)"
assert_eq   "cidr6 /128 is host"    "2001:db8::1" "$(normalize_cidr 2001:DB8::0001/128)"
assert_eq   "cidr6 odd prefix"      "2001:db8:8000::/33" "$(normalize_cidr 2001:db8:ffff::/33)"
assert_fail "cidr4 prefix 33"       normalize_cidr 10.0.0.0/33
assert_fail "cidr6 prefix 129"      normalize_cidr ::/129
assert_fail "cidr bad prefix"       normalize_cidr 10.0.0.0/abc
assert_ok   "domain valid"          is_domain git.example.com
assert_fail "domain no tld"         is_domain localhost
assert_fail "domain injection"      is_domain 'a.com;rm'
assert_ok   "cidr overlap"          cidr4_overlap 10.203.0.0/16 10.203.5.0/24
assert_fail "cidr no overlap"       cidr4_overlap 10.203.0.0/16 10.204.0.0/16
assert_eq   "pool subnet"           "10.204.7.0/24" "$(pool_subnet 10.204.0.0/16 7)"

echo "== dotenv parsing (data, never code)"
cat >"${TMP}/x.env" <<'EOF'
# comment
A=plain
B="double quoted value"
C='single $(not executed)'
D=value # trailing comment
export E=exported
F=$(touch /tmp/1s-pwned)
EOF
( env_load "${TMP}/x.env"
  assert_eq "plain"  plain "${A}"; assert_eq "double" "double quoted value" "${B}"
  assert_eq "single" 'single $(not executed)' "${C}"; assert_eq "trailing comment" value "${D}"
  assert_eq "export" exported "${E}"; assert_eq "no command substitution" '$(touch' "${F%% *}"
  exit "${TESTS_FAILED}" ) || TESTS_FAILED=$((TESTS_FAILED + 1))
TESTS_RUN=$((TESTS_RUN + 6))
assert_fail "no file created by env_load" test -e /tmp/1s-pwned
assert_eq   "env_quote roundtrip" "it's \$x" "$(printf 'V=%s\n' "$(env_quote "it's \$x")" >"${TMP}/q.env"; env_get "${TMP}/q.env" V)"

echo "== configuration validation"
( load_fixture; config_validate shared gitea openhands ) >/dev/null 2>&1 \
  && pass "fixture config valid" || fail "fixture config valid"
( load_fixture; GITEA_BIND_IP=300.1.1.1; config_validate gitea ) >/dev/null 2>&1 \
  && fail "invalid bind ip rejected" || pass "invalid bind ip rejected"
( load_fixture; GITEA_SSH_PORT=443; config_validate gitea ) >/dev/null 2>&1 \
  && fail "ssh/https collision rejected" || pass "ssh/https collision rejected"
( load_fixture; OPENHANDS_USERS="alice:443,bob:443"; config_validate openhands ) >/dev/null 2>&1 \
  && fail "duplicate user port rejected" || pass "duplicate user port rejected"
( load_fixture; OPENHANDS_USERS="alice:80"; config_validate openhands ) >/dev/null 2>&1 \
  && fail "port 80 rejected" || pass "port 80 rejected"
( load_fixture; OPENHANDS_USERS="Alice:8443"; config_validate openhands ) >/dev/null 2>&1 \
  && fail "uppercase user rejected" || pass "uppercase user rejected"
( load_fixture; OPENHANDS_SUBNET_POOL=10.203.0.0/16; config_validate gitea openhands ) >/dev/null 2>&1 \
  && fail "overlapping pools rejected" || pass "overlapping pools rejected"
( load_fixture; GITEA_RUNNER_IMAGE=gitea/runner:6.0.0; config_validate gitea ) >/dev/null 2>&1 \
  && fail "rootless needs dind-rootless image" || pass "rootless needs dind-rootless image"
( load_fixture; unset GITEA_SECRET_KEY; config_validate gitea ) >/dev/null 2>&1 \
  && fail "missing secret rejected" || pass "missing secret rejected"
( load_fixture; unset GITEA_SECRET_KEY GITEA_DOMAIN; config_validate shared openhands ) >/dev/null 2>&1 \
  && pass "gitea settings optional when gitea is not deployed" || fail "gitea settings optional when gitea is not deployed"
( load_fixture; GITEA_SSH_BIND_IP=""; GITEA_SSH_DOMAIN=""; config_apply_defaults
  [[ "${GITEA_SSH_BIND_IP}" == 203.0.113.10 && "${GITEA_SSH_DOMAIN}" == git.example.com ]] ) \
  && pass "defaults referencing other settings" || fail "defaults referencing other settings"
assert_ok "reference docs up to date" bash "${REPO}/scripts/dev/generate-reference.sh" --check

echo "== OpenHands per-user isolation"
(
  load_fixture
  a1="$(oh_user_index alice)"; b1="$(oh_user_index bob)"; a2="$(oh_user_index alice)"
  [[ "${a1}" == 1 && "${b1}" == 2 && "${a2}" == 1 ]] || exit 1
  [[ "$(oh_user_api_key alice)" != "$(oh_user_api_key bob)" ]] || exit 1
  [[ "$(oh_user_api_key alice)" == "$(oh_user_api_key alice)" ]] || exit 1
  [[ "$(oh_user_api_key alice)" =~ ^[0-9a-f]{64}$ ]] || exit 1
  [[ "$(oh_user_secret_key alice)" != "$(oh_user_api_key alice)" ]] || exit 1
  # Known-answer test: HMAC-SHA256("test-api-master", "1s/openhands/api/alice")
  want="$(printf '%s' "1s/openhands/api/alice" | openssl dgst -sha256 -hmac test-api-master -r | cut -d' ' -f1)"
  [[ "$(oh_user_api_key alice)" == "${want}" ]] || exit 1
  [[ "$(oh_subnet "${b1}")" == 10.204.2.0/24 && "$(oh_local_port "${b1}")" == 28002 ]] || exit 1
) && pass "stable indices, distinct derived keys, subnets and ports" || fail "stable indices, distinct derived keys, subnets and ports"

echo "== Nginx rendering"
(
  load_fixture
  mkdir -p "${ONES_VAR}/state" "${ACCESS_DIR}"
  touch "${ONES_VAR}/state/gitea.deployed" "${ONES_VAR}/state/openhands.deployed"
  printf '198.51.100.10  # office\n2001:db8:1::/48\n' >"${ACCESS_DIR}/gitea.allow"
  printf '198.51.100.20\n' >"${ACCESS_DIR}/openhands.allow"
  nginx_render "${TMP}/gen/G1"
) >/dev/null 2>&1 && pass "render succeeds" || fail "render succeeds"
G="${TMP}/gen/G1"
assert_contains     "gitea allow office"          "${G}/access/gitea.conf" '^allow 198\.51\.100\.10;'
assert_contains     "gitea allow ipv6 cidr"       "${G}/access/gitea.conf" '^allow 2001:db8:1::/48;'
assert_contains     "gitea allows runner pool"    "${G}/access/gitea.conf" '^allow 10\.203\.0\.0/16;'
assert_not_contains "gitea does not allow OH pool" "${G}/access/gitea.conf" '10\.204\.'
assert_not_contains "openhands list independent"  "${G}/access/openhands.conf" '198\.51\.100\.10'
assert_contains     "default deny after allowlist" "${G}/servers/10-gitea.conf" 'deny all;'
assert_contains     "explicit IPv4 listen"        "${G}/servers/10-gitea.conf" 'listen 203\.0\.113\.10:443 ssl;'
assert_contains     "explicit IPv6 listen"        "${G}/servers/10-gitea.conf" 'listen \[2001:db8::10\]:443 ssl;'
assert_not_contains "no wildcard listeners"       "${G}/servers/10-gitea.conf" 'listen (80|443|\*|\[::\])'
assert_contains     "http redirect"               "${G}/servers/10-gitea.conf" 'return 301 https://git\.example\.com'
assert_contains     "acme challenge served"       "${G}/snippets/acme.conf" 'acme-challenge'
assert_contains     "user alice on 443"           "${G}/servers/20-openhands.conf" 'listen 203\.0\.113\.20:443 ssl;'
assert_contains     "user bob on 8444"            "${G}/servers/20-openhands.conf" 'listen 203\.0\.113\.20:8444 ssl;'
assert_contains     "alice upstream"              "${G}/servers/20-openhands.conf" 'proxy_pass http://127\.0\.0\.1:28001;'
assert_contains     "bob upstream"                "${G}/servers/20-openhands.conf" 'proxy_pass http://127\.0\.0\.1:28002;'
assert_contains     "websocket upgrade"           "${G}/snippets/proxy.conf" 'Connection +\$connection_upgrade'
assert_contains     "XFF overwritten, not appended" "${G}/snippets/proxy.conf" 'X-Forwarded-For +\$remote_addr;'
assert_not_contains "no proxy_add_x_forwarded_for" "${G}/snippets/proxy.conf" 'proxy_add_x_forwarded_for'
assert_contains     "unknown SNI rejected"        "${G}/servers/00-default.conf" 'ssl_reject_handshake on;'
assert_contains     "default server on bob port"  "${G}/servers/00-default.conf" 'listen 203\.0\.113\.20:8444 ssl default_server;'
assert_not_contains "no real_ip without proxies"  "${G}/nginx.conf" 'set_real_ip_from'
(
  load_fixture; TRUSTED_PROXIES="192.0.2.0/24"
  mkdir -p "${ONES_VAR}/state"; nginx_render "${TMP}/gen/G2"
) >/dev/null 2>&1
assert_contains     "trusted proxies honoured"    "${TMP}/gen/G2/nginx.conf" 'set_real_ip_from 192\.0\.2\.0/24;'
(
  load_fixture; OPENHANDS_ALLOW_GITEA=true; nginx_render "${TMP}/gen/G3"
) >/dev/null 2>&1
assert_contains     "OPENHANDS_ALLOW_GITEA adds OH pool" "${TMP}/gen/G3/access/gitea.conf" '^allow 10\.204\.0\.0/16;'

echo "== ip-access (allowlist management)"
IPA="${REPO}/scripts/access/ip-access.sh"
rm -rf "${ONES_ETC}" "${ONES_VAR}"; mkdir -p "${ONES_VAR}/state"
cp "${TESTS_DIR}/fixtures/test.env" "${TMP}/cfg.env"; mkdir -p "${ONES_ETC}/config"
cp "${TMP}/cfg.env" "${ONES_ETC}/config/gitea.env"
cp "${TMP}/cfg.env" "${ONES_ETC}/config/shared.env"
cp "${TMP}/cfg.env" "${ONES_ETC}/config/openhands.env"
assert_ok   "add before deploy (stored only)" "${IPA}" add gitea 198.51.100.10
assert_ok   "add duplicate is idempotent"     "${IPA}" add gitea 198.51.100.10/32
assert_eq   "no duplicate line" 1 "$(grep -c '^198\.51\.100\.10 ' "${ONES_ETC}/access/gitea.allow")"
assert_fail "reject invalid address"          "${IPA}" add gitea 198.51.100.300
assert_fail "reject shell metacharacters"     "${IPA}" add gitea '1.2.3.4;id'
assert_fail "reject unknown component"        "${IPA}" add gitlab 198.51.100.1
assert_fail "reject whole internet"           "${IPA}" add gitea 0.0.0.0/0
assert_ok   "add ipv6 cidr"                   "${IPA}" add openhands 2001:db8:abcd::/48 --comment "vpn"
assert_ok   "check allowed ipv6"              "${IPA}" check openhands 2001:db8:abcd:1::5
assert_fail "check denied ipv6"               "${IPA}" check openhands 2001:db8:abce::5
assert_ok   "check allowed ipv4"              "${IPA}" check gitea 198.51.100.10
assert_fail "lists are independent"           "${IPA}" check openhands 198.51.100.10
touch "${ONES_VAR}/state/gitea.deployed" "${ONES_VAR}/state/shared.deployed"
export STUB_DOCKER_LOG="${TMP}/docker.log" STUB_STATE="${TMP}/docker-stub.state"
mkdir -p "${ONES_ETC}/tls/git.example.com"
assert_ok   "add when deployed applies nginx" "${IPA}" add gitea 198.51.100.11
assert_contains "nginx validated"  "${TMP}/docker.log" 'nginx -t'
assert_contains "nginx reloaded"   "${TMP}/docker.log" 'nginx -s reload'
assert_contains "new generation active" "$(readlink -f "${ONES_ETC}/nginx/current")/access/gitea.conf" '^allow 198\.51\.100\.11;'
before="$(readlink "${ONES_ETC}/nginx/current")"
export STUB_FAIL_NGINX_T="${TMP}/fail"; touch "${STUB_FAIL_NGINX_T}"
assert_fail "invalid nginx config is rejected" "${IPA}" add gitea 198.51.100.12
assert_not_contains "rolled back allowlist" "${ONES_ETC}/access/gitea.allow" '198\.51\.100\.12'
assert_eq   "previous generation still active" "${before}" "$(readlink "${ONES_ETC}/nginx/current")"
rm -f "${STUB_FAIL_NGINX_T}"
assert_ok   "remove entry"                    "${IPA}" remove gitea 198.51.100.10
assert_fail "removed entry denied"            "${IPA}" check gitea 198.51.100.10
assert_ok   "remove missing entry is a no-op" "${IPA}" remove gitea 198.51.100.99
assert_fail "reset requires --yes"            "${IPA}" reset gitea
assert_ok   "reset with --yes"                "${IPA}" reset gitea --yes
assert_fail "after reset everyone denied"     "${IPA}" check gitea 198.51.100.11
unset STUB_FAIL_NGINX_T STUB_DOCKER_LOG

echo "== deployment gateway input validation"
GW="${REPO}/scripts/server/gateway.sh"
if id nobody >/dev/null 2>&1 && command -v runuser >/dev/null; then
  gw() { SSH_ORIGINAL_COMMAND="$1" runuser -u nobody -- env SSH_ORIGINAL_COMMAND="$1" bash "${GW}" 2>&1; }
  for bad in "" "bash" "deploy" "deploy gitea" "deploy gitea abc" "deploy gitlab $(printf 'a%.0s' {1..40})" \
             'deploy gitea $(id)' "deploy gitea ${RANDOM};id" "health all extra" "rollback gitea --force" \
             "backup shared" "status now" "ping;id" "../../bin/sh"; do
    out="$(gw "${bad}")"
    if [[ "${out}" == *"rejected"* ]]; then pass "gateway rejects '${bad}'"; else fail "gateway rejects '${bad}'" "${out}"; fi
  done
  out="$(gw "deploy gitea $(printf '0%.0s' {1..40})")"
  if [[ "${out}" != *"rejected"* ]]; then pass "gateway accepts a valid deploy (then needs sudo)"; else fail "gateway accepts a valid deploy" "${out}"; fi
else
  echo "  (skipped: needs runuser and user nobody)"
fi

echo "== deployment bundle (code only)"
if command -v git >/dev/null; then
  R="${TMP}/repo"; mkdir -p "${R}"
  tar -C "${REPO}" --exclude=.git --exclude=.env --exclude='.tmp-*' -cf - . | tar -C "${R}" -xf -
  git -C "${R}" init -q && git -C "${R}" add -A && git -C "${R}" -c user.name=t -c user.email=t@example.com commit -qm t
  sha="$(git -C "${R}" rev-parse HEAD)"
  mkdir -p "${TMP}/b"
  if bash "${R}/scripts/deploy/make-bundle.sh" "${sha}" >"${TMP}/b.tar" 2>"${TMP}/b.err"; then
    pass "bundle built"
    tar -xf "${TMP}/b.tar" -C "${TMP}/b"
    assert_eq "bundle has only code and metadata" "meta.env release.tar.gz" "$(find "${TMP}/b" -mindepth 1 -printf "%f\n" | sort | tr '\n' ' ' | sed 's/ $//')"
    assert_ok "release archive valid" tar -tzf "${TMP}/b/release.tar.gz"
    assert_fail "no .env in the release" sh -c "tar -tzf '${TMP}/b/release.tar.gz' | grep -qx '\\.env'"
  else
    fail "bundle built" "$(cat "${TMP}/b.err")"
  fi
  assert_fail "invalid sha rejected" bash "${R}/scripts/deploy/make-bundle.sh" 'HEAD;id'
fi

echo "== server configuration import"
CFG="${REPO}/scripts/server/config.sh"
rm -rf "${ONES_ETC}"
assert_ok   "import fixture"              "${CFG}" import <"${TESTS_DIR}/fixtures/test.env"
assert_eq   "secrets file is 0600"        600 "$(stat -c %a "${ONES_ETC}/secrets/gitea.env")"
assert_contains     "settings split per component" "${ONES_ETC}/config/gitea.env" '^GITEA_DOMAIN=git\.example\.com$'
assert_not_contains "no secrets in settings"       "${ONES_ETC}/config/gitea.env" 'PASSWORD|SECRET_KEY'
assert_not_contains "no foreign settings"          "${ONES_ETC}/config/gitea.env" 'OPENHANDS_|ACME_'
assert_not_contains "defaults not stored"          "${ONES_ETC}/config/gitea.env" '^GITEA_IMAGE='
grep -v '^GITEA_SECRET_KEY=\|^OPENHANDS_API_MASTER_KEY=' "${TESTS_DIR}/fixtures/test.env" >"${TMP}/nosecret.env"
assert_ok   "re-import without secrets"   "${CFG}" import <"${TMP}/nosecret.env"
assert_eq   "existing secret kept"        "test-secret-key" "$(env_get "${ONES_ETC}/secrets/gitea.env" GITEA_SECRET_KEY)"
rm -rf "${ONES_ETC}"
assert_ok   "first import generates secrets" "${CFG}" import <"${TMP}/nosecret.env"
gen="$(env_get "${ONES_ETC}/secrets/openhands.env" OPENHANDS_API_MASTER_KEY)"
assert_ok   "generated secret is strong" test "${#gen}" -ge 40
pw="$(bash "${CFG}" secret GITEA_ADMIN_PASSWORD)"
assert_eq   "secret command prints value" "test-admin-password-123" "${pw}"
before="$(md5sum "${ONES_ETC}/config/gitea.env")"
sed 's/^GITEA_BIND_IP=.*/GITEA_BIND_IP=999.1.1.1/' "${TESTS_DIR}/fixtures/test.env" >"${TMP}/bad.env"
assert_fail "invalid import rejected"     "${CFG}" import <"${TMP}/bad.env"
assert_eq   "nothing changed after invalid import" "${before}" "$(md5sum "${ONES_ETC}/config/gitea.env")"
printf 'SERVER_SSH=root@203.0.113.5\nACME_EMAIL=a@example.com\nENABLE_GITEA=false\nOPENHANDS_DOMAIN=ai.example.com\nOPENHANDS_BIND_IP=203.0.113.20\nOPENHANDS_USERS=alice:443\n' >"${TMP}/ohonly.env"
assert_ok   "OpenHands-only configuration valid" "${CFG}" import <"${TMP}/ohonly.env"
assert_ok   "rotate a secret"             "${CFG}" rotate GITEA_INTERNAL_TOKEN
assert_fail "encryption keys need --yes"  "${CFG}" rotate GITEA_SECRET_KEY

summary
