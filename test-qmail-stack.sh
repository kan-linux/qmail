#!/bin/bash
# test-qmail-stack.sh — test qmail + vpopmail + DKIM + TLS on a local network
#
# Requirements:
#   - kan-linux.org resolves to 127.0.0.1 (/etc/hosts or local DNS)
#   - /etc/init.d/smtp and /etc/init.d/pop3 are running
#   - TLS: /etc/init.d/smtps and /etc/init.d/pop3s (ports 465 / 995)
#   - DKIM is set up (/var/qmail/dkim/mail.private)
#
# Usage:
#   sudo ./test-qmail-stack.sh              # run all checks
#   sudo ./test-qmail-stack.sh --send-only  # send one test mail and check DKIM
#   ./test-qmail-stack.sh --dns             # only check DNS/hosts
#
# Test account: test@kan-linux.org  password: test123 (from build-qmail-stack.sh)

set -euo pipefail

QMAIL_HOME=${QMAIL_HOME:-/var/qmail}
VPOPMAIL_DIR=${VPOPMAIL_DIR:-/var/vpopmail}
DOMAIN=${QMAIL_DOMAIN:-kan-linux.org}
DOMAIN_LC=${DOMAIN,,}
TEST_USER=${TEST_USER:-test}
TEST_PASS=${TEST_PASS:-test123}
SELECTOR=${DKIM_SELECTOR:-mail}
DKIM_DIR=${DKIM_DIR:-/var/qmail/dkim}
SMTP_HOST=${SMTP_HOST:-127.0.0.1}
POP3_HOST=${POP3_HOST:-127.0.0.1}

PASS=0
FAIL=0
SKIP=0

green() { printf '\033[1;32m%s\033[0m\n' "$*"; }
red()   { printf '\033[1;31m%s\033[0m\n' "$*"; }
yellow(){ printf '\033[1;33m%s\033[0m\n' "$*"; }

ok()   { green "  [PASS] $*"; PASS=$((PASS+1)); }
bad()  { red   "  [FAIL] $*"; FAIL=$((FAIL+1)); }
skip() { yellow "  [SKIP] $*"; SKIP=$((SKIP+1)); }

section() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }

# ---------------------------------------------------------------------------
check_dns() {
  section "DNS / resolve (expect ${DOMAIN} -> 127.0.0.1)"
  local ip
  # Prefer IPv4 A records; getent may return IPv6 first
  ip=$(getent ahostsv4 "$DOMAIN_LC" 2>/dev/null | awk '{print $1}' | grep -E '^(127\.|10\.|192\.168\.|172\.)' | head -1)
  if [[ -z "$ip" ]]; then
    ip=$(getent hosts "$DOMAIN_LC" | awk '{print $1}' | head -1)
  fi
  if [[ -n "$ip" ]]; then
    ok "${DOMAIN_LC} resolves to ${ip}"
  else
    bad "${DOMAIN_LC} cannot resolve (check /etc/hosts or DNS)"
    return
  fi
  if [[ "$ip" == "127.0.0.1" ]]; then
    ok "resolved to 127.0.0.1 (local test mode)"
  else
    yellow "  [INFO] resolved to ${ip} (not 127.0.0.1; for local test set 127.0.0.1 in /etc/hosts)"
  fi

  # MX (may be missing on local net; just a hint)
  if command -v dig >/dev/null; then
    local mx
    mx=$(dig +short MX "$DOMAIN_LC" 2>/dev/null | head -1)
    if [[ -n "$mx" ]]; then
      ok "MX: $mx"
    else
      skip "no MX record (ok for local test; required in production)"
    fi
  fi
}

# ---------------------------------------------------------------------------
check_ports() {
  section "ports / qmail-send"
  if ss -lnt 2>/dev/null | grep -q ':25 '; then
    ok "SMTP 25 is listening"
  else
    bad "SMTP 25 is not listening — run /etc/init.d/smtp"
  fi
  if ss -lnt 2>/dev/null | grep -q ':110 '; then
    ok "POP3 110 is listening"
  else
    bad "POP3 110 is not listening — run /etc/init.d/pop3"
  fi
  if ss -lnt 2>/dev/null | grep -q ':465 '; then
    ok "SMTP-TLS 465 is listening"
  else
    bad "SMTP-TLS 465 is not listening — run /etc/init.d/smtps"
  fi
  if ss -lnt 2>/dev/null | grep -q ':995 '; then
    ok "POP3-TLS 995 is listening"
  else
    bad "POP3-TLS 995 is not listening — run /etc/init.d/pop3s"
  fi
  # Without qmail-send, mail only sits in the queue
  if pgrep -f 'qmail-send|qmail-start|splogger' >/dev/null 2>&1; then
    ok "qmail-send/qmail-start is running"
  else
    bad "qmail-send is not running — mail will stay in the queue. Run: /etc/init.d/smtp (starts rc) or ${QMAIL_HOME}/rc &"
  fi
}

# ---------------------------------------------------------------------------
check_smtp_banner() {
  section "SMTP banner"
  local out
  out=$(printf 'QUIT\r\n' | nc -w 3 "$SMTP_HOST" 25 2>/dev/null || true)
  if grep -q '^220' <<<"$out"; then
    ok "220 banner: $(head -1 <<<"$out")"
  else
    bad "SMTP banner bad: ${out:-no response}"
  fi
}

# ---------------------------------------------------------------------------
check_pop3_banner() {
  section "POP3 banner"
  local out
  out=$(printf 'QUIT\r\n' | nc -w 3 "$POP3_HOST" 110 2>/dev/null || true)
  if grep -q '^+OK' <<<"$out"; then
    ok "+OK banner: $(head -1 <<<"$out")"
  else
    bad "POP3 banner bad: ${out:-no response}"
  fi
}

# ---------------------------------------------------------------------------
# Implicit TLS (sslwrap) on 465 / 995 — same protocol, encrypted channel
check_tls_banner() {
  section "TLS banners (implicit TLS via sslwrap)"
  if ! command -v openssl >/dev/null; then
    skip "openssl not found, cannot test TLS ports"
    return
  fi

  local out
  out=$(printf 'QUIT\r\n' | timeout 5 openssl s_client \
    -connect "${SMTP_HOST}:465" -quiet 2>/dev/null || true)
  if grep -q '^220' <<<"$out"; then
    ok "SMTP-TLS 465 banner: $(head -1 <<<"$out")"
  else
    bad "SMTP-TLS 465 no 220 banner (start /etc/init.d/smtps)"
  fi

  out=$(printf 'QUIT\r\n' | timeout 5 openssl s_client \
    -connect "${POP3_HOST}:995" -quiet 2>/dev/null || true)
  if grep -q '^+OK' <<<"$out"; then
    ok "POP3-TLS 995 banner: $(head -1 <<<"$out")"
  else
    bad "POP3-TLS 995 no +OK banner (start /etc/init.d/pop3s)"
  fi
}

# ---------------------------------------------------------------------------
check_pop3_auth_tls() {
  section "POP3 login over TLS (${TEST_USER}@${DOMAIN_LC})"
  local out
  out=$(printf 'USER %s\nPASS %s\nSTAT\nQUIT\r\n' "$TEST_USER" "$TEST_PASS" \
    | timeout 8 openssl s_client -connect "${POP3_HOST}:995" -quiet 2>/dev/null || true)
  if grep -q '^+OK' <<<"$out"; then
    ok "POP3-TLS auth/STAT ok"
    echo "$out" | grep -E '^\+OK' | head -3 | sed 's/^/  /'
  else
    bad "POP3-TLS login failed"
    echo "$out" | head -5 | sed 's/^/  /'
  fi
}

# ---------------------------------------------------------------------------
check_local_inject() {
  section "local delivery (qmail-inject -> test@${DOMAIN_LC})"
  local maildir="$VPOPMAIL_DIR/domains/${DOMAIN_LC}/${TEST_USER}/Maildir/new"
  # Maildir may use a hash layout
  if [[ ! -d "$maildir" ]]; then
    maildir=$(find "$VPOPMAIL_DIR/domains" -type d -path "*/${TEST_USER}/Maildir/new" 2>/dev/null | head -1 || true)
  fi

  local before=0 after=0
  if [[ -d "$maildir" ]]; then
    before=$(find "$maildir" -type f 2>/dev/null | wc -l || true)
  fi

  local marker="stack-test-$$-$(date +%s)"
  local inject_err=""
  if inject_err=$(printf 'to: %s@%s\nsubject: %s\n\nbody %s\n' \
      "$TEST_USER" "$DOMAIN_LC" "$marker" "$marker" \
      | timeout 8 "$QMAIL_HOME/bin/qmail-inject" 2>&1); then
    ok "qmail-inject ok (marker=${marker})"
  else
    bad "qmail-inject failed/timeout: ${inject_err:-no response in 8s, need root or check qmail-send}"
    [[ $(id -u) -ne 0 ]] && yellow "  [hint] re-run with sudo (qmail-queue needs root)"
    return
  fi

  sleep 1
  if [[ -d "$maildir" ]]; then
    after=$(find "$maildir" -type f 2>/dev/null | wc -l || true)
    if [[ "$after" -gt "$before" ]]; then
      ok "Maildir got new mail: ${maildir} (${before} -> ${after})"
      return
    fi
  fi

  # Search queue / vpopmail for marker (queue file names have no subject)
  local hit
  hit=$(timeout 8 grep -rl "$marker" "$QMAIL_HOME/queue" "$VPOPMAIL_DIR/domains" 2>/dev/null | head -3 || true)
  if [[ -n "$hit" ]]; then
    ok "found mail file with marker:"
    echo "$hit" | sed 's/^/    /'
    if pgrep -f 'qmail-send|qmail-start' >/dev/null 2>&1; then
      yellow "  [INFO] qmail-send is running; wait a few seconds or check ${QMAIL_HOME}/queue"
    else
      bad "qmail-send is not running, mail stays in queue — start: /etc/init.d/smtp or ${QMAIL_HOME}/rc &"
    fi
  else
    bad "marker=${marker} not found in queue or Maildir"
    yellow "  [debug] sudo ${QMAIL_HOME}/bin/qmail-qread ; sudo ls ${QMAIL_HOME}/queue"
  fi
}

# ---------------------------------------------------------------------------
check_dkim_key() {
  section "DKIM key"
  local key="$DKIM_DIR/${SELECTOR}.private"
  local txt="$DKIM_DIR/${SELECTOR}.txt"
  if [[ -s "$key" ]]; then
    ok "private key exists: $key"
  else
    bad "missing private key $key — run sudo ./build-qmail-stack.sh"
    return
  fi
  if [[ -s "$txt" ]]; then
    ok "DNS TXT draft: $txt"
    echo "  ----- put this in DNS -----"
    sed 's/^/  /' "$txt"
    echo "  ---------------------------"
  else
    skip "no $txt"
  fi
}

# ---------------------------------------------------------------------------
# Send one mail via SMTP and look for DKIM-Signature
check_smtp_dkim() {
  section "SMTP delivery + DKIM sign"
  local to_addr="test@${DOMAIN_LC}"
  local subject="dkim-smtp-test-$$-$(date +%s)"
  local msg
  msg=$(cat <<EOF
HELO ${DOMAIN_LC}
MAIL FROM: <test@${DOMAIN_LC}>
RCPT TO: <${to_addr}>
DATA
From: test@${DOMAIN_LC}
To: ${to_addr}
Subject: ${subject}
Date: $(date -R)
Message-ID: <${subject}@${DOMAIN_LC}>

This is a DKIM signing test from test-qmail-stack.sh
.
QUIT
EOF
)

  # Convert to CRLF and send to port 25
  local out
  out=$(printf '%s' "$msg" | sed 's/$/\r/' | timeout 8 nc -w 5 "$SMTP_HOST" 25 2>/dev/null || true)
  echo "$out" | sed 's/^/  | /'

  if grep -qE '^250 ' <<<"$out"; then
    ok "SMTP accepted (250)"
  else
    bad "SMTP session did not return 250"
    return
  fi

  # Wait for delivery
  sleep 2

  # Find the mail in Maildir and check DKIM-Signature
  local found=""
  found=$(timeout 5 grep -rl --include='*' "$subject" \
      "$VPOPMAIL_DIR/domains" 2>/dev/null | head -1 || true)
  if [[ -n "$found" ]]; then
    ok "mail delivered: $found"
    if grep -qi 'DKIM-Signature:' "$found"; then
      ok "has DKIM-Signature header"
      grep -i 'DKIM-Signature:' "$found" | head -1 | sed 's/^/  /'
    else
      bad "mail has no DKIM-Signature (qmail-remote wrapper or key not active)"
    fi
  else
    # May still be in the queue
    if grep -rl "$subject" "$QMAIL_HOME/queue" 2>/dev/null | head -1 | grep -q .; then
      ok "mail is in the queue (remote delivery or later)"
    else
      bad "mail with Subject=${subject} not found"
    fi
  fi
}

# ---------------------------------------------------------------------------
check_pop3_auth() {
  section "POP3 login (${TEST_USER}@${DOMAIN_LC})"
  local out
  out=$(printf 'USER %s\nPASS %s\nSTAT\nQUIT\r\n' "$TEST_USER" "$TEST_PASS" \
    | nc -w 3 "$POP3_HOST" 110 2>/dev/null || true)
  if grep -q '^+OK' <<<"$out"; then
    ok "POP3 auth/STAT ok"
    echo "$out" | grep -E '^\+OK' | head -3 | sed 's/^/  /'
  else
    bad "POP3 login failed"
    echo "$out" | head -5 | sed 's/^/  /'
  fi
}

# ---------------------------------------------------------------------------
check_qmail_remote_wrapper() {
  section "qmail-remote DKIM wrapper"
  local w="$QMAIL_HOME/bin/qmail-remote"
  local real="$QMAIL_HOME/bin/qmail-remote.bin"
  if [[ -x "$w" ]] && grep -q 'DKIM signing wrapper' "$w" 2>/dev/null; then
    ok "qmail-remote is a DKIM wrapper"
  else
    bad "qmail-remote has no DKIM wrapper — run sudo ./build-qmail-stack.sh"
  fi
  if [[ -x "$real" ]]; then
    ok "original qmail-remote saved: $real"
  else
    skip "no qmail-remote.bin (maybe not wrapped yet)"
  fi
}

# ---------------------------------------------------------------------------
summary() {
  section "summary"
  echo "  PASS=${PASS}  FAIL=${FAIL}  SKIP=${SKIP}"
  if [[ $FAIL -eq 0 ]]; then
    green "all key checks passed."
  else
    red "some checks failed, see [FAIL] above."
  fi
}

# ---------------------------------------------------------------------------
main() {
  local mode=${1:-all}
  case "$mode" in
    --dns)       check_dns; summary; exit 0 ;;
    --send-only) check_dns; check_ports; check_smtp_dkim; summary; exit 0 ;;
    -h|--help)   sed -n '2,15p' "$0"; exit 0 ;;
  esac

  check_dns
  check_ports
  check_smtp_banner
  check_pop3_banner
  check_tls_banner
  check_local_inject
  check_dkim_key
  check_qmail_remote_wrapper
  check_smtp_dkim
  check_pop3_auth
  check_pop3_auth_tls
  summary
}

main "$@"
