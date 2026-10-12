#!/bin/bash
# build-qmail-stack.sh — build and install qmail + ucspi-tcp + vpopmail + TLS
# for Kan-Linux and common Linux distros.
#
# Usage:
#   sudo ./build-qmail-stack.sh            # full build + install (with OpenDKIM DKIM)
#   sudo ./build-qmail-stack.sh clean      # clean source trees (make clean)
#   sudo ./build-qmail-stack.sh uninstall  # remove /var/qmail /var/vpopmail and more
#   ./build-qmail-stack.sh smoke-test      # smoke test only (no rebuild, must be installed)
#   ./build-qmail-stack.sh help            # show help (same as -h / --help)
#
# DKIM env vars:
#   DKIM_SELECTOR=mail     selector, default mail
#   DKIM_DIR=/var/qmail/dkim
#   DKIM_KEYBITS=2048
# Key file: ${DKIM_DIR}/<selector>.private
# DNS TXT:  <selector>._domainkey.<domain>  (printed at end of install)
#
# Start services with /etc/init.d/smtp and /etc/init.d/pop3
# (same as qmail-install.txt). TLS listeners:
#   /etc/init.d/smtps   SMTP over TLS on port 465 (implicit TLS)
#   /etc/init.d/pop3s   POP3 over TLS on port 995 (implicit TLS)
# TLS cert: /var/qmail/control/servercert.pem (generated if missing)
#
# Env overrides:
#   QMAIL_HOSTNAME=mail.example.com   default $(hostname -f) or $(hostname)
#   QMAIL_DOMAIN=example.com          default from HOSTNAME
#   VPOPMAIL_DIR=/var/vpopmail
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
QMAIL_SRC="${SCRIPT_DIR}/qmail"
UCSPI_SRC="${SCRIPT_DIR}/ucspi-tcp"
VPOPMAIL_SRC="${SCRIPT_DIR}/vpopmail"
OPENDKIM_SRC="${OPENDKIM_SRC:-${SCRIPT_DIR}/opendkim}"
SSLWRAP_SRC="${SCRIPT_DIR}/sslwrap"

QMAIL_HOME=/var/qmail
VPOPMAIL_DIR="${VPOPMAIL_DIR:-/var/vpopmail}"
UCSPI_HOME=/usr/local
DKIM_DIR="${DKIM_DIR:-/var/qmail/dkim}"
DKIM_SELECTOR="${DKIM_SELECTOR:-mail}"
DKIM_KEYBITS="${DKIM_KEYBITS:-2048}"

# Modern gcc: C23 rejects K&R empty parameter lists
CC_CMD='gcc -O2 -std=gnu89 -Wno-error -fcommon'
LD_CMD='gcc -s'

SMOKE_TEST=0
DO_CLEAN=0
DO_UNINSTALL=0
for arg in "$@"; do
  case "$arg" in
    clean)        DO_CLEAN=1 ;;
    uninstall)    DO_UNINSTALL=1 ;;
    smoke-test)   SMOKE_TEST=1 ;;
    help|-h|--help)
      sed -n '2,29p' "$0"; exit 0 ;;
    *)
      echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

log()  { printf '\n\033[1;32m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33mWARN: %s\033[0m\n' "$*" >&2; }
die()  { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

# Replace only the leading value lines of a conf-* file.
# Keep the comment lines after them (djb style).
# Usage: set_conf <file> <value>...
set_conf() {
  local file="$1"
  shift
  local nlines=$#
  local rest="" first_lines=""
  if [[ -f "$file" ]]; then
    rest=$(tail -n +$((nlines + 1)) "$file" || true)
    first_lines=$(head -n "$nlines" "$file" || true)
  fi
  # Skip write if already the target value (keep git clean)
  local want
  want=$(printf '%s\n' "$@")
  if [[ "$first_lines" == "$want" ]]; then
    return 0
  fi
  {
    printf '%s\n' "$@"
    if [[ -n "$rest" ]]; then
      printf '%s\n' "$rest"
    fi
  } > "$file"
}

need_root() {
  [[ $(id -u) -eq 0 ]] || die "please run as root (system users, make setup, vpopmail all need root). Example: sudo $0"
}

# ---------------------------------------------------------------------------
# 0. Preflight checks
# ---------------------------------------------------------------------------
preflight() {
  log "preflight checks"
  [[ -d "$QMAIL_SRC"    ]] || die "qmail source not found: $QMAIL_SRC"
  [[ -d "$UCSPI_SRC"    ]] || die "ucspi-tcp source not found: $UCSPI_SRC"
  [[ -d "$VPOPMAIL_SRC" ]] || die "vpopmail source not found: $VPOPMAIL_SRC"
  [[ -d "$SSLWRAP_SRC"  ]] || die "sslwrap source not found: $SSLWRAP_SRC"

  command -v gcc >/dev/null  || die "gcc is required"
  command -v make >/dev/null || die "make is required"
  command -v openssl >/dev/null || die "openssl is required (TLS cert and tests)"

  local gcc_major
  gcc_major=$(gcc -dumpversion | cut -d. -f1)
  log "gcc $(gcc -dumpversion)  (major=$gcc_major)"
  if [[ "$gcc_major" -ge 14 ]]; then
    warn "GCC >= 14 defaults to C23; will compile K&R source with -std=gnu89"
  fi

  QMAIL_HOSTNAME="${QMAIL_HOSTNAME:-$(hostname -f 2>/dev/null || hostname)}"
  QMAIL_DOMAIN="${QMAIL_DOMAIN:-${QMAIL_HOSTNAME#*.}}"
  if [[ "$QMAIL_DOMAIN" == "$QMAIL_HOSTNAME" ]]; then
    QMAIL_DOMAIN="${QMAIL_HOSTNAME}"
  fi
  log "HOSTNAME=$QMAIL_HOSTNAME  DOMAIN=$QMAIL_DOMAIN"

  # Missing build tools: only warn, do not install packages
  local pkg
  for pkg in nroff groff; do
    command -v "$pkg" >/dev/null || warn "$pkg not found; man page build may fail (try: sudo apt install groff-base)"
  done
}

# ---------------------------------------------------------------------------
# 1. Create groups and users for qmail / vpopmail
# (qmail-install.txt steps 1 and 7)
# ---------------------------------------------------------------------------
create_users() {
  log "create groups and users for qmail"

  getent group nofiles >/dev/null || groupadd nofiles
  getent group qmail   >/dev/null || groupadd qmail

  # user_exists <name> <gid> <home>
  local name gid home
  while read -r name gid home; do
    if getent passwd "$name" >/dev/null; then
      log "user $name exists, skip"
    else
      useradd -g "$gid" -d "$home" -s /sbin/nologin -M "$name"
      log "created user $name (group=$gid home=$home)"
    fi
  done <<'EOF'
alias  nofiles  /var/qmail/alias
qmaild nofiles  /var/qmail
qmaill nofiles  /var/qmail
qmailp nofiles  /var/qmail
qmailq qmail    /var/qmail
qmailr qmail    /var/qmail
qmails qmail    /var/qmail
EOF

  # vpopmail / vchkpw  (qmail-install.txt step 7)
  getent group vchkpw >/dev/null || groupadd -g 89 vchkpw
  if getent passwd vpopmail >/dev/null; then
    log "user vpopmail exists, skip"
  else
    # uid 89 may be taken on Ubuntu, so do not force -u 89
    useradd -g vchkpw -d "$VPOPMAIL_DIR" -s /sbin/nologin -M vpopmail
    log "created user vpopmail (gid=vchkpw home=$VPOPMAIL_DIR)"
  fi

  mkdir -p /var/qmail/alias
  mkdir -p "$VPOPMAIL_DIR"
  chown alias:nofiles /var/qmail/alias
  chown vpopmail:vchkpw "$VPOPMAIL_DIR"
}

# ---------------------------------------------------------------------------
# 2. Build qmail
# ---------------------------------------------------------------------------
build_qmail() {
  log "build qmail (conf-cc -> -std=gnu89)"
  cd "$QMAIL_SRC"

  set_conf conf-cc "$CC_CMD"
  set_conf conf-ld "$LD_CMD"
  # Keep distro user/group names; auto-uid looks up uid by name
  set_conf conf-users alias qmaild qmaill root qmailp qmailq qmailr qmails
  set_conf conf-groups qmail nofiles

  make clean >/dev/null 2>&1 || true
  # 'make it' compiles only, no install
  make it

  log "qmail build output:"
  ls -l qmail-send qmail-smtpd qmail-pop3d qmail-inject qmail-queue qmail-local
}

install_qmail() {
  log "install qmail -> $QMAIL_HOME (make setup check)"
  cd "$QMAIL_SRC"
  mkdir -p "$QMAIL_HOME"
  make setup check

  # qmail-install.txt step 5: boot/home -> rc, Mailbox -> Maildir
  # Note: qmail-start execvp()s qmail-send etc via PATH.
  # They must be under /var/qmail/bin, else _exit(111) with no error.
  cp "$QMAIL_HOME/boot/home" "$QMAIL_HOME/rc"
  chmod 755 "$QMAIL_HOME/rc"
  sed -i 's|./Mailbox|./Maildir/|g' "$QMAIL_HOME/rc"
  # Rewrite rc with absolute paths, no need for caller PATH
  cat > "$QMAIL_HOME/rc" <<EOF
#!/bin/sh
# qmail queue daemon (qmail-start + qmail-send)
# qmail-send/lspawn/rspawn/clean are found via PATH, so set it here
exec env - PATH="${QMAIL_HOME}/bin:/usr/bin:/bin" \\
  ${QMAIL_HOME}/bin/qmail-start ./Maildir/ ${QMAIL_HOME}/bin/splogger qmail
EOF
  chmod 755 "$QMAIL_HOME/rc"
  echo "--- $QMAIL_HOME/rc ---"
  cat "$QMAIL_HOME/rc"

  # qmail-install.txt step 4: system aliases
  cd /var/qmail/alias
  touch .qmail-postmaster .qmail-mailer-daemon .qmail-root
  chmod 644 .qmail-*
  chown alias:nofiles .qmail-*

  # qmail-install.txt step 6: skel Maildir
  mkdir -p /etc/skel
  # maildirmake is fatal if target exists, so make this idempotent
  if [[ -d /etc/skel/Maildir/cur && -d /etc/skel/Maildir/new && -d /etc/skel/Maildir/tmp ]]; then
    log "/etc/skel/Maildir exists, skip maildirmake"
  else
    "$QMAIL_HOME/bin/maildirmake" /etc/skel/Maildir \
      || warn "maildirmake /etc/skel/Maildir failed (dir may already exist, can ignore)"
  fi
  echo './Maildir/' > /etc/skel/.qmail
  chmod 644 /etc/skel/.qmail

  # config-fast writes control/me and other control files
  # Note: config-fast is not installed to /var/qmail/bin; run from source dir
  log "write qmail control files (config-fast ${QMAIL_HOSTNAME})"
  if [[ -x "$QMAIL_SRC/config-fast" ]]; then
    ( cd "$QMAIL_SRC" && ./config-fast "$QMAIL_HOSTNAME" )
  elif [[ -f "$QMAIL_SRC/config-fast.sh" ]]; then
    ( cd "$QMAIL_SRC" && sed "s}QMAIL}$QMAIL_HOME}g" config-fast.sh > config-fast \
        && chmod 755 config-fast && ./config-fast "$QMAIL_HOSTNAME" )
  fi
  # Fallback: always write control/me (missing it makes qmail-smtpd return 421)
  ensure_control_files
  chmod 644 "$QMAIL_HOME/control/me"
  log "control/me = $(cat "$QMAIL_HOME/control/me")"

  log "qmail install done: $("$QMAIL_HOME/bin/qmail-showctl" 2>&1 | head -8)"
}

# ---------------------------------------------------------------------------
# 3. Build ucspi-tcp
# ---------------------------------------------------------------------------
build_ucspi() {
  log "build ucspi-tcp (conf-cc -> -std=gnu89)"
  cd "$UCSPI_SRC"
  set_conf conf-cc "$CC_CMD"
  set_conf conf-ld "$LD_CMD"
  set_conf conf-home "$UCSPI_HOME"

  make clean >/dev/null 2>&1 || true
  make
  ls -l tcpserver tcprules tcpclient
}

install_ucspi() {
  log "install ucspi-tcp -> $UCSPI_HOME"
  cd "$UCSPI_SRC"
  make setup check
  command -v tcpserver >/dev/null && tcpserver 2>&1 | head -3 || true
}

# ---------------------------------------------------------------------------
# 3b. Build / install sslwrap (TLS around tcpserver)
# ---------------------------------------------------------------------------
build_sslwrap() {
  log "build sslwrap (TLS wrapper)"
  cd "$SSLWRAP_SRC"
  make clean >/dev/null 2>&1 || true
  make
  ls -l sslwrap
}

install_sslwrap() {
  log "install sslwrap -> $UCSPI_HOME/bin"
  cd "$SSLWRAP_SRC"
  make install PREFIX="$UCSPI_HOME"
  [[ -x "$UCSPI_HOME/bin/sslwrap" ]] || die "sslwrap not installed to $UCSPI_HOME/bin"
}

# Self-signed server cert for implicit TLS (ports 465 / 995).
# Combined PEM (cert + key) in qmail style: control/servercert.pem.
# Readable by qmaild (group nofiles) because tcpserver drops privs
# before exec'ing sslwrap.
setup_tls_cert() {
  local cert="$QMAIL_HOME/control/servercert.pem"
  log "TLS server cert: $cert"
  mkdir -p "$QMAIL_HOME/control"
  if [[ -s "$cert" ]]; then
    log "TLS cert exists, skip generate"
    return 0
  fi
  local tmpdir
  tmpdir=$(mktemp -d)
  # SAN covers the mail hostname clients connect to
  openssl req -x509 -newkey rsa:2048 -nodes -sha256 \
    -keyout "$tmpdir/key.pem" -out "$tmpdir/cert.pem" \
    -days 3650 -subj "/CN=${QMAIL_HOSTNAME}" \
    -addext "subjectAltName=DNS:${QMAIL_HOSTNAME}" \
    >/dev/null 2>&1 || die "openssl req failed (cannot create TLS cert)"
  cat "$tmpdir/cert.pem" "$tmpdir/key.pem" > "$cert"
  rm -rf "$tmpdir"
  chmod 640 "$cert"
  chown root:nofiles "$cert" 2>/dev/null || true
  log "created self-signed cert for CN=${QMAIL_HOSTNAME}"
  log "replace with a real cert anytime (same file path, cert then key PEM)"
}

# ---------------------------------------------------------------------------
# 4. Build / install vpopmail
# ---------------------------------------------------------------------------
build_vpopmail() {
  log "configure and build vpopmail"
  cd "$VPOPMAIL_SRC"

  # Modern gcc also needs -std=gnu89; pass CFLAGS to configure too
  export CFLAGS="-O2 -std=gnu89 -Wno-error -fcommon"
  export CXXFLAGS="$CFLAGS"

  # --enable-roaming-users must find tcprules at configure time.
  # Full install has ucspi-tcp in /usr/local/bin; otherwise use the one
  # just built in the source tree.
  local tcprules_path
  if [[ -x "$UCSPI_HOME/bin/tcprules" ]]; then
    tcprules_path="$UCSPI_HOME/bin/tcprules"
  else
    tcprules_path="$UCSPI_SRC/tcprules"
  fi

  # Quota and default domain are written after make install.
  local conf_opts=(
    --enable-roaming-users=y
    --enable-tcprules-prog="${tcprules_path}"
    --enable-passwd=n
    --enable-log-name=vpopmail
    --enable-auth-logging=y
    --enable-logging=y
    --enable-vpopuser=vpopmail
    --enable-vpopgroup=vchkpw
  )

  log "./configure ${conf_opts[*]}"
  ./configure "${conf_opts[@]}"

  # configure.in hardcodes at the end: echo "${CC} -O2" > cdb/conf-cc
  # That drops CFLAGS. cdb/ is djb-style and needs -std=gnu89 again.
  echo "$CC_CMD" > cdb/conf-cc
  echo "$LD_CMD" > cdb/conf-ld
  rm -f cdb/compile cdb/load cdb/*.o
  log "patched cdb/conf-cc: $(cat cdb/conf-cc)"

  make clean >/dev/null 2>&1 || true
  make

  log "install vpopmail -> $VPOPMAIL_DIR"
  make install-strip || make install

  # vpopmail: default quota in ~vpopmail/etc/vlimits.default
  # (old docs used --enable-defaultquota=10485760, 10MB)
  local vlimits="$VPOPMAIL_DIR/etc/vlimits.default"
  if [[ -f "$vlimits" ]]; then
    if grep -qE '^[[:space:]]*default_quota[[:space:]]' "$vlimits"; then
      sed -i -E 's|^[[:space:]]*#?[[:space:]]*default_quota[[:space:]].*|default_quota\t\t10485760|' "$vlimits"
    else
      sed -i -E 's|^#default_quota[[:space:]].*|default_quota\t\t10485760|' "$vlimits"
      grep -qE '^[[:space:]]*default_quota[[:space:]]' "$vlimits" \
        || printf '\ndefault_quota\t\t10485760\n' >> "$vlimits"
    fi
    log "set vlimits.default: default_quota=10485760 (10MB)"
  else
    warn "$vlimits not found (make install should create it), skip quota setup"
  fi

  # vpopmail: default domain in ~vpopmail/etc/defaultdomain
  # (vpopmail lowerit()s the name)
  # Old docs used --enable-default-domain=kan-linux.org
  echo "${QMAIL_DOMAIN,,}" > "$VPOPMAIL_DIR/etc/defaultdomain"
  log "set defaultdomain=${QMAIL_DOMAIN,,}"

  # qmail-install.txt: vchkpw is setgid
  chmod 6755 "$VPOPMAIL_DIR/bin/vchkpw" 2>/dev/null || true

  # Allow localhost in tcp.smtp
  mkdir -p "$VPOPMAIL_DIR/etc"
  echo '127.0.0.1:allow,RELAYCLIENT=""' > "$VPOPMAIL_DIR/etc/tcp.smtp"
  chown -R vpopmail:vchkpw "$VPOPMAIL_DIR"
  "$UCSPI_HOME/bin/tcprules" \
    "$VPOPMAIL_DIR/etc/tcp.smtp.cdb" \
    "$VPOPMAIL_DIR/etc/tcp.smtp.tmp" \
    < "$VPOPMAIL_DIR/etc/tcp.smtp"

  # Virtual domain + test user (qmail-install.txt step 7)
  # vpopmail lowerit()s the domain and writes /var/qmail/users/assign + cdb.
  # Dir layout may use hash; trust the tool output, not just -d.
  local domain_lc="${QMAIL_DOMAIN,,}"
  if [[ "$QMAIL_DOMAIN" != *.* ]]; then
    warn "domain '${QMAIL_DOMAIN}' has no '.', not a normal mail domain (docs use kan-linux.org)."
    warn "  try: QMAIL_DOMAIN=mail.example.com sudo $0 clean && sudo $0"
  fi

  log "create virtual domain ${QMAIL_DOMAIN} and test user"
  local out rc
  set +e
  # Password is the 2nd arg; vgetpasswd reads /dev/tty so pipes do not work
  out=$("$VPOPMAIL_DIR/bin/vadddomain" "$domain_lc" 'postmaster123' 2>&1)
  rc=$?
  set -e
  if [[ $rc -eq 0 ]]; then
    log "vadddomain ${domain_lc} ok (postmaster password: postmaster123)"
  elif grep -qiE 'already exists|Username exists' <<<"$out"; then
    log "virtual domain ${domain_lc} exists, skip"
  else
    warn "vadddomain failed: $out"
  fi

  set +e
  # vadduser password is the 2nd arg (same /dev/tty issue)
  out=$("$VPOPMAIL_DIR/bin/vadduser" "test@${domain_lc}" 'test123' 2>&1)
  rc=$?
  set -e
  if [[ $rc -eq 0 ]]; then
    log "vadduser test@${domain_lc} ok"
  elif grep -qiE 'already exists|Username exists' <<<"$out"; then
    log "test user test@${domain_lc} exists, skip"
  else
    warn "vadduser failed: $out"
  fi

  # clearopensmtp cron job
  # Note: set -e + pipefail: grep with no match would kill the pipe
  {
    crontab -l 2>/dev/null | grep -v clearopensmtp || true
    echo "40 * * * * ${VPOPMAIL_DIR}/bin/clearopensmtp >/dev/null 2>&1"
  } | crontab - || warn "failed to install clearopensmtp crontab"
  log "installed clearopensmtp crontab"
}

# ---------------------------------------------------------------------------
# 5. Init scripts (qmail-install.txt step 7: /etc/init.d/smtp and pop3)
# ---------------------------------------------------------------------------

# qmail-install.txt: -u/-g are qmaild uid and gid (primary group nofiles)
# Note: id -g <name> looks up a user, not a group. Do not use id -g nofiles.
qmaild_ids() {
  qmaild_uid=$(id -u qmaild 2>/dev/null) || qmaild_uid=""
  qmaild_gid=$(id -g qmaild 2>/dev/null) || qmaild_gid=""
  if [[ -z "$qmaild_gid" ]]; then
    qmaild_gid=$(getent group nofiles | cut -d: -f3 || true)
  fi
  [[ -n "$qmaild_uid" && -n "$qmaild_gid" ]] \
    || die "cannot resolve qmaild uid/gid (missing user qmaild or group nofiles). Install first: sudo $0"
}

# Missing control/me makes qmail-smtpd return 421 unable to read controls
ensure_control_files() {
  if [[ -s "$QMAIL_HOME/control/me" ]]; then
    return 0
  fi
  warn "missing $QMAIL_HOME/control/me, write ${QMAIL_HOSTNAME}"
  mkdir -p "$QMAIL_HOME/control"
  echo "$QMAIL_HOSTNAME" > "$QMAIL_HOME/control/me"
  chmod 644 "$QMAIL_HOME/control/me"
}

# Install /etc/init.d/smtp, pop3 (plain) and smtps, pop3s (TLS) as in
# qmail-install.txt. TLS ports use sslwrap around tcpserver.
install_init_scripts() {
  local qmaild_uid qmaild_gid
  qmaild_ids

  log "write /etc/init.d/smtp pop3 smtps pop3s"
  cat > /etc/init.d/smtp <<EOF
#!/bin/sh
# smtp start script from qmail-install.txt
# qmail-send log: /var/qmail/log/qmail-send.err
mkdir -p ${QMAIL_HOME}/log 2>/dev/null
bash -cf '${QMAIL_HOME}/rc >>${QMAIL_HOME}/log/qmail-send.err 2>&1 &'
exec ${UCSPI_HOME}/bin/tcpserver -H -R -l 0 -t 1 -x \\
  ${VPOPMAIL_DIR}/etc/tcp.smtp.cdb -c 100 -u ${qmaild_uid} -g ${qmaild_gid} 0 smtp \\
  ${QMAIL_HOME}/bin/qmail-smtpd ${QMAIL_HOSTNAME} \\
  ${VPOPMAIL_DIR}/bin/vchkpw /bin/true 2>&1 >/dev/null &
EOF
  cat > /etc/init.d/pop3 <<EOF
#!/bin/sh
exec ${UCSPI_HOME}/bin/tcpserver -q -l 0 -H -c 100 -R 0 pop-3 \\
  ${QMAIL_HOME}/bin/qmail-popup ${QMAIL_HOSTNAME} ${VPOPMAIL_DIR}/bin/vchkpw \\
  ${QMAIL_HOME}/bin/qmail-pop3d Maildir 2>&1 >/dev/null &
EOF
  cat > /etc/init.d/smtps <<EOF
#!/bin/sh
# SMTP over TLS (implicit TLS, port 465) via sslwrap
exec ${UCSPI_HOME}/bin/tcpserver -H -R -l 0 -t 1 -x \\
  ${VPOPMAIL_DIR}/etc/tcp.smtp.cdb -c 100 -u ${qmaild_uid} -g ${qmaild_gid} 0 465 \\
  ${UCSPI_HOME}/bin/sslwrap -c ${QMAIL_HOME}/control/servercert.pem \\
  ${QMAIL_HOME}/bin/qmail-smtpd ${QMAIL_HOSTNAME} \\
  ${VPOPMAIL_DIR}/bin/vchkpw /bin/true 2>&1 >/dev/null &
EOF
  cat > /etc/init.d/pop3s <<EOF
#!/bin/sh
# POP3 over TLS (implicit TLS, port 995) via sslwrap
exec ${UCSPI_HOME}/bin/tcpserver -q -l 0 -H -c 100 -R 0 995 \\
  ${UCSPI_HOME}/bin/sslwrap -c ${QMAIL_HOME}/control/servercert.pem \\
  ${QMAIL_HOME}/bin/qmail-popup ${QMAIL_HOSTNAME} ${VPOPMAIL_DIR}/bin/vchkpw \\
  ${QMAIL_HOME}/bin/qmail-pop3d Maildir 2>&1 >/dev/null &
EOF
  chmod 755 /etc/init.d/smtp /etc/init.d/pop3 /etc/init.d/smtps /etc/init.d/pop3s
  log "init.d scripts ready (smtp pop3 smtps pop3s)"
}

# ---------------------------------------------------------------------------
# 6. Smoke test (qmail-install.txt test section)
# ---------------------------------------------------------------------------
smoke_test() {
  log "smoke test"

  echo "--- local delivery (qmail-inject) ---"
  local domain_lc="${QMAIL_DOMAIN,,}"
  if echo "to: test@${domain_lc}" | "$QMAIL_HOME/bin/qmail-inject"; then
    log "qmail-inject ok"
  else
    warn "qmail-inject returned non-zero (ok if brand-new queue)"
  fi
  sleep 1
  find "$VPOPMAIL_DIR/domains" -path '*/Maildir/new/*' 2>/dev/null | head -5 || true

  echo "--- SMTP banner test ---"
  local banner
  banner=$(printf 'QUIT\r\n' | nc -w 3 127.0.0.1 25 2>/dev/null || true)
  if [[ -z "$banner" ]]; then
    warn "SMTP no response (port 25 may not be listening)"
  else
    echo "$banner"
    if grep -q '^220' <<<"$banner"; then
      log "SMTP banner ok (220)"
    else
      warn "SMTP banner is not 220; check control files and service log"
      [[ -s "$QMAIL_HOME/control/me" ]] || warn "missing $QMAIL_HOME/control/me"
    fi
  fi

  echo "--- POP3 banner test ---"
  banner=$(printf 'QUIT\r\n' | nc -w 3 127.0.0.1 110 2>/dev/null || true)
  if [[ -n "$banner" ]]; then
    echo "$banner" | head -2
    grep -q '^+OK' <<<"$banner" && log "POP3 banner ok (+OK)" \
      || warn "POP3 banner is not +OK"
  else
    warn "POP3 no response (port 110 may not be listening)"
  fi

  echo "--- SMTP over TLS (port 465) ---"
  banner=$(printf 'QUIT\r\n' | timeout 5 openssl s_client \
    -connect 127.0.0.1:465 -quiet 2>/dev/null || true)
  if grep -q '^220' <<<"$banner"; then
    log "SMTP-TLS banner ok (220)"
  else
    warn "SMTP-TLS no 220 banner (port 465). Start: /etc/init.d/smtps"
  fi

  echo "--- POP3 over TLS (port 995) ---"
  banner=$(printf 'QUIT\r\n' | timeout 5 openssl s_client \
    -connect 127.0.0.1:995 -quiet 2>/dev/null || true)
  if grep -q '^+OK' <<<"$banner"; then
    log "POP3-TLS banner ok (+OK)"
  else
    warn "POP3-TLS no +OK banner (port 995). Start: /etc/init.d/pop3s"
  fi

  if ! ss -lnt 2>/dev/null | grep -q ':25 ' && ! netstat -lnt 2>/dev/null | grep -q ':25 '; then
    warn "port 25 is not listening. Start services first:"
    if [[ -x /etc/init.d/smtp ]]; then
      warn "  /etc/init.d/smtp ; /etc/init.d/pop3"
    else
      warn "  missing /etc/init.d/smtp, reinstall: sudo $0"
    fi
  fi

  echo "--- listening ports ---"
  ss -lntp 2>/dev/null | grep -E ':25|:110|:465|:995' \
    || netstat -lntp 2>/dev/null | grep -E ':25|:110|:465|:995' || true

  log "smoke test done. For remote delivery, point MX here and test with telnet 0 25"
}

# ---------------------------------------------------------------------------
# 5b. OpenDKIM — libopendkim sign + qmail-remote wrapper
# ---------------------------------------------------------------------------
# qmail has no milter; use opendkim-testmsg for outbound DKIM,
# then hand off to the real qmail-remote.
build_opendkim() {
  log "build OpenDKIM (libopendkim, --disable-filter)"
  [[ -d "$OPENDKIM_SRC" ]] || die "opendkim source not found: $OPENDKIM_SRC"
  cd "$OPENDKIM_SRC"

  # After copy/extract, timestamps can be off (Makefile.am vs Makefile.in
  # may differ by nanoseconds). make then calls automake-1.13 / autoconf,
  # which are usually not installed.
  # Touch outputs in dependency order:
  # inputs -> aclocal.m4 -> configure -> Makefile.in -> generated files.
  # Wrong order can make aclocal.m4 newer than configure and trigger autoconf.
  _touch_autotools_outputs() {
    find . \( -name 'configure.ac' -o -name 'Makefile.am' -o -name '*.m4' \) \
      ! -path './autom4te.cache/*' -print0 | xargs -0 touch
    sleep 0.01
    touch aclocal.m4
    sleep 0.01
    touch configure config.h.in build-config.h.in 2>/dev/null || true
    sleep 0.01
    find . -name 'Makefile.in' -print0 | xargs -0 touch
    sleep 0.01
    touch Makefile config.status build-config.h stamp-h1 libtool 2>/dev/null || true
    find . -name 'Makefile' -print0 | xargs -0 touch
    rm -rf autom4te.cache
  }

  _touch_autotools_outputs

  # OpenSSL 3 removed SSL_library_init; configure probe can mis-detect
  ./configure --prefix=/usr/local \
    --disable-filter \
    --disable-live-testing \
    --disable-shared \
    ac_cv_search_SSL_library_init=-lssl

  # configure rewrites Makefile/config.status; align times again
  _touch_autotools_outputs

  make -j"$(nproc)"
  log "OpenDKIM build done"
}

install_opendkim() {
  log "install OpenDKIM -> /usr/local"
  cd "$OPENDKIM_SRC"
  make install
  chmod 755 /usr/local/sbin/opendkim-genkey /usr/local/bin/opendkim-genkey 2>/dev/null || true
  # Tools may land in sbin or bin; use absolute paths later
  local t
  for t in /usr/local/sbin/opendkim-testmsg /usr/local/bin/opendkim-testmsg; do
    [[ -x "$t" ]] && log "opendkim-testmsg: $t"
  done
  [[ -x /usr/local/sbin/opendkim-genkey || -x /usr/local/bin/opendkim-genkey ]] \
    || die "opendkim-genkey not installed"
  [[ -x /usr/local/sbin/opendkim-testmsg || -x /usr/local/bin/opendkim-testmsg ]] \
    || die "opendkim-testmsg not installed"
}

# Make DKIM key + wrap qmail-remote
setup_dkim() {
  local domain_lc="${QMAIL_DOMAIN,,}"
  local keyfile="$DKIM_DIR/${DKIM_SELECTOR}.private"
  local txtfile="$DKIM_DIR/${DKIM_SELECTOR}.txt"
  local genkey testmsg
  genkey=$(command -v opendkim-genkey 2>/dev/null \
    || ls /usr/local/sbin/opendkim-genkey /usr/local/bin/opendkim-genkey 2>/dev/null | head -1)
  testmsg=$(command -v opendkim-testmsg 2>/dev/null \
    || ls /usr/local/sbin/opendkim-testmsg /usr/local/bin/opendkim-testmsg 2>/dev/null | head -1)

  log "setup DKIM (selector=${DKIM_SELECTOR} domain=${domain_lc})"
  [[ -n "$genkey" && -x "$genkey" ]] || die "opendkim-genkey not found; run install_opendkim first"
  [[ -n "$testmsg" && -x "$testmsg" ]] || die "opendkim-testmsg not found; run install_opendkim first"

  mkdir -p "$DKIM_DIR"
  chown root:qmail "$DKIM_DIR" 2>/dev/null || true
  chmod 750 "$DKIM_DIR"

  if [[ -s "$keyfile" ]]; then
    log "DKIM key exists, skip generate: $keyfile"
  else
    log "generate key: $genkey --bits=$DKIM_KEYBITS --domain=$domain_lc --selector=$DKIM_SELECTOR"
    "$genkey" --bits="$DKIM_KEYBITS" --domain="$domain_lc" \
      --selector="$DKIM_SELECTOR" --directory="$DKIM_DIR" \
      --subdomains --restrict
    [[ -s "$keyfile" ]] || die "key generate failed, no $keyfile"
    chmod 640 "$keyfile" "$txtfile"
    chown root:qmail "$keyfile" "$txtfile" 2>/dev/null || true
    log "DKIM key created: $keyfile"
  fi

  # Save real qmail-remote as qmail-remote.bin (idempotent)
  local real="$QMAIL_HOME/bin/qmail-remote.bin"
  local wrapper="$QMAIL_HOME/bin/qmail-remote"
  if [[ ! -x "$real" ]]; then
    if [[ -x "$wrapper" ]] && ! grep -q 'DKIM signing wrapper' "$wrapper" 2>/dev/null; then
      log "save original qmail-remote -> qmail-remote.bin"
      mv "$wrapper" "$real"
    elif [[ -x "$QMAIL_SRC/qmail-remote" ]]; then
      cp "$QMAIL_SRC/qmail-remote" "$real"
    else
      die "no executable qmail-remote, cannot install DKIM wrapper"
    fi
    chmod 755 "$real"
  fi

  log "install DKIM signing wrapper for qmail-remote"
  cat > "$wrapper" <<EOF
#!/bin/sh
# DKIM signing wrapper for qmail-remote (by build-qmail-stack.sh)
# same usage as qmail-remote: qmail-remote host sender recip...
DKIM_DIR="$DKIM_DIR"
SELECTOR="$DKIM_SELECTOR"
DOMAIN="${domain_lc}"
REAL="$real"
TESTMSG="$testmsg"
[ -x "\$TESTMSG" ] || TESTMSG="/usr/local/sbin/opendkim-testmsg"
[ -x "\$TESTMSG" ] || TESTMSG="/usr/local/bin/opendkim-testmsg"

umask 077
in=\$(mktemp) || exit 111
out=\$(mktemp) || { rm -f "\$in"; exit 111; }
trap 'rm -f "\$in" "\$out"' EXIT INT TERM

# queue uses LF; DKIM needs CRLF
awk 'BEGIN{ORS="\\r\\n"} {print}' > "\$in"

key="\$DKIM_DIR/\$SELECTOR.private"
if [ -s "\$key" ] && [ -x "\$TESTMSG" ]; then
  if "\$TESTMSG" -C -s "\$SELECTOR" -d "\$DOMAIN" -k "\$key" \\
      < "\$in" > "\$out" 2>/dev/null && [ -s "\$out" ]; then
    exec "\$REAL" "\$@" < "\$out"
  fi
fi
# if sign fails, deliver as-is
exec "\$REAL" "\$@" < "\$in"
EOF
  chmod 755 "$wrapper"
  chown root:qmail "$wrapper" 2>/dev/null || true

  log "DKIM ready. Add this TXT record to DNS:"
  echo "----------------------------------------"
  cat "$txtfile" 2>/dev/null || true
  echo "----------------------------------------"
}

# ---------------------------------------------------------------------------
# Clean build products in source trees (does not uninstall /var/qmail)
# ---------------------------------------------------------------------------
do_clean() {
  log "clean build products (make clean)"
  local dir
  for dir in "$QMAIL_SRC" "$UCSPI_SRC"; do
    if [[ -f "$dir/Makefile" ]]; then
      log "make clean -> $dir"
      ( cd "$dir" && make clean ) || warn "make clean failed: $dir"
    fi
  done

  # vpopmail: Makefile needs config.status; without it make clean runs
  # --recheck and fails
  if [[ -f "$VPOPMAIL_SRC/Makefile" && -f "$VPOPMAIL_SRC/config.status" ]]; then
    log "make clean -> $VPOPMAIL_SRC"
    ( cd "$VPOPMAIL_SRC" && make clean ) || warn "make clean failed: $VPOPMAIL_SRC"
  else
    log "vpopmail has no config.status, skip make clean and remove products"
  fi
  # configure / build products (make clean may not remove all of these)
  rm -f "$VPOPMAIL_SRC/config.log" "$VPOPMAIL_SRC/config.status" \
        "$VPOPMAIL_SRC/stamp-h1" "$VPOPMAIL_SRC/config.h" \
        "$VPOPMAIL_SRC/libvpopmail.a" "$VPOPMAIL_SRC"/*.o \
        "$VPOPMAIL_SRC"/vchkpw "$VPOPMAIL_SRC"/vadddomain \
        "$VPOPMAIL_SRC"/vadduser "$VPOPMAIL_SRC"/vdelivermail \
        "$VPOPMAIL_SRC"/vpasswd "$VPOPMAIL_SRC"/vpopmaild 2>/dev/null || true
  rm -rf "$VPOPMAIL_SRC/autom4te.cache" 2>/dev/null || true
  if [[ -d "$VPOPMAIL_SRC/cdb" ]]; then
    rm -f "$VPOPMAIL_SRC/cdb"/*.o "$VPOPMAIL_SRC/cdb"/*.a \
          "$VPOPMAIL_SRC/cdb/uint32.h" "$VPOPMAIL_SRC/cdb/systype" \
          "$VPOPMAIL_SRC/cdb/compile" "$VPOPMAIL_SRC/cdb/load" \
          "$VPOPMAIL_SRC/cdb/conf-cc" "$VPOPMAIL_SRC/cdb/conf-ld" 2>/dev/null || true
  fi
  if [[ -d "$OPENDKIM_SRC" ]]; then
    log "make clean -> $OPENDKIM_SRC"
    ( cd "$OPENDKIM_SRC" && make clean ) || warn "make clean failed: $OPENDKIM_SRC"
  fi
  if [[ -d "$SSLWRAP_SRC" ]]; then
    log "make clean -> $SSLWRAP_SRC"
    ( cd "$SSLWRAP_SRC" && make clean ) || warn "make clean failed: $SSLWRAP_SRC"
  fi
  log "clean done (files in ${QMAIL_HOME} / ${VPOPMAIL_DIR} not touched)"
}

# ---------------------------------------------------------------------------
# Full uninstall: /var/qmail, /var/vpopmail, init.d, system users/groups
# (not reversible)
# ---------------------------------------------------------------------------
do_uninstall() {
  need_root

  cat <<EOF

Will delete all of this (not reversible):
  - ${QMAIL_HOME}          (queue, control files, binaries, DKIM key ${DKIM_DIR}, TLS cert)
  - ${VPOPMAIL_DIR}        (virtual domain mailboxes, account db)
  - /etc/init.d/smtp  /etc/init.d/pop3  /etc/init.d/smtps  /etc/init.d/pop3s
  - /etc/skel/Maildir  /etc/skel/.qmail
  - clearopensmtp crontab entry
  - system users: alias qmaild qmaill qmailp qmailq qmailr qmails vpopmail
  - system groups: nofiles qmail vchkpw

All mail data will be lost!

EOF

  # Stop related processes (tcpserver / sslwrap / qmail-send)
  log "stop qmail processes"
  pkill -f '/usr/local/bin/tcpserver.*smtp' 2>/dev/null || true
  pkill -f '/usr/local/bin/tcpserver.*pop-3' 2>/dev/null || true
  pkill -f '/usr/local/bin/tcpserver.*:465' 2>/dev/null || true
  pkill -f '/usr/local/bin/tcpserver.*0 465' 2>/dev/null || true
  pkill -f '/usr/local/bin/tcpserver.*0 995' 2>/dev/null || true
  pkill -f '/usr/local/bin/sslwrap' 2>/dev/null || true
  pkill -f '/var/qmail/bin/qmail-send' 2>/dev/null || true
  pkill -f '/var/qmail/rc' 2>/dev/null || true
  sleep 1

  log "remove /etc/init.d/smtp pop3 smtps pop3s"
  rm -f /etc/init.d/smtp /etc/init.d/pop3 /etc/init.d/smtps /etc/init.d/pop3s

  log "remove ${QMAIL_HOME}"
  rm -rf "${QMAIL_HOME}"

  log "remove ${VPOPMAIL_DIR}"
  rm -rf "${VPOPMAIL_DIR}"

  log "remove /etc/skel mail templates"
  rm -rf /etc/skel/Maildir
  rm -f /etc/skel/.qmail

  # clearopensmtp crontab
  if crontab -l 2>/dev/null | grep -q clearopensmtp; then
    log "remove clearopensmtp crontab"
    ( crontab -l 2>/dev/null | grep -v clearopensmtp ) | crontab - || true
  fi

  # system users / groups
  log "remove system users and groups"
  local u
  for u in alias qmaild qmaill qmailp qmailq qmailr qmails vpopmail; do
    if getent passwd "$u" >/dev/null; then
      userdel "$u" 2>/dev/null || warn "cannot delete user $u (maybe still running)"
    fi
  done
  local g
  for g in nofiles qmail vchkpw; do
    if getent group "$g" >/dev/null; then
      groupdel "$g" 2>/dev/null || warn "cannot delete group $g"
    fi
  done

  # Drop sendmail symlink if it still points to qmail
  if [[ -L /usr/sbin/sendmail || -L /usr/lib/sendmail ]]; then
    local sm
    for sm in /usr/sbin/sendmail /usr/lib/sendmail; do
      if [[ -L "$sm" ]] && readlink "$sm" | grep -q qmail; then
        log "remove sendmail -> qmail symlink: $sm"
        rm -f "$sm"
      fi
    done
  fi

  log "uninstall done"
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------
already_installed() {
  [[ -x "$QMAIL_HOME/bin/qmail-send" && -x "$QMAIL_HOME/bin/qmail-smtpd" ]]
}

# for smoke-test: resolve HOSTNAME/DOMAIN (same as preflight)
resolve_names() {
  QMAIL_HOSTNAME="${QMAIL_HOSTNAME:-$(hostname -f 2>/dev/null || hostname)}"
  QMAIL_DOMAIN="${QMAIL_DOMAIN:-${QMAIL_HOSTNAME#*.}}"
  if [[ "$QMAIL_DOMAIN" == "$QMAIL_HOSTNAME" ]]; then
    QMAIL_DOMAIN="${QMAIL_HOSTNAME}"
  fi
}

main() {
  if [[ ${DO_CLEAN} -eq 1 ]]; then
    do_clean
    exit 0
  fi

  if [[ ${DO_UNINSTALL} -eq 1 ]]; then
    do_uninstall
    exit 0
  fi

  if [[ ${SMOKE_TEST} -eq 1 ]]; then
    already_installed || die "$QMAIL_HOME/bin not installed yet. Run full install first: sudo $0"
    resolve_names
    log "HOSTNAME=$QMAIL_HOSTNAME  DOMAIN=$QMAIL_DOMAIN"
    smoke_test
    exit 0
  fi

  preflight
  need_root
  create_users
  build_qmail
  install_qmail
  # init.d scripts are created with qmail install (qmail-install.txt step 7),
  # independent of later ucspi/vpopmail success
  install_init_scripts
  ensure_control_files
  build_ucspi
  install_ucspi
  build_sslwrap
  install_sslwrap
  setup_tls_cert
  build_vpopmail

  # OpenDKIM (outbound sign)
  if [[ -d "$OPENDKIM_SRC" ]]; then
    build_opendkim
    install_opendkim
    setup_dkim
  else
    warn "no $OPENDKIM_SRC, skip DKIM"
  fi

  # If already written above this is a no-op; covers partial runs
  if [[ ! -x /etc/init.d/smtp || ! -x /etc/init.d/pop3 \
     || ! -x /etc/init.d/smtps || ! -x /etc/init.d/pop3s ]]; then
    install_init_scripts
  fi

  log "all done."
  cat <<EOF

Next manual steps (from qmail-install.txt):
  1. DNS:  A  ${QMAIL_HOSTNAME} -> this machine IP
           MX ${QMAIL_DOMAIN}   -> ${QMAIL_HOSTNAME}
  2. hostnamectl set-hostname ${QMAIL_HOSTNAME}
  3. start:  /etc/init.d/smtp ; /etc/init.d/pop3
             /etc/init.d/smtps ; /etc/init.d/pop3s   (TLS on 465 / 995)
  4. test:   telnet 0 25   /   echo to: test@${QMAIL_DOMAIN} | /var/qmail/bin/qmail-inject
  5. user mail dir: ~/Maildir/  (already in skel)
  6. run tests only:  $0 smoke-test

Notes for Ubuntu 26.04 / GCC15 / vpopmail 5.4:
  * must use -std=gnu89, else K&R empty () is treated as (void) and compile fails
  * -fcommon: old code defines the same global in multiple units
  * qmail is IPv4 only, no built-in STARTTLS
  * TLS is Phase 1 wrapper style: tcpserver + sslwrap on ports 465 / 995
    (implicit TLS). Client settings: SMTP 465 SSL/TLS, POP3 995 SSL/TLS.
    Cert: ${QMAIL_HOME}/control/servercert.pem (self-signed by default)
  * vpopmail configure must run as root (it checks uid)
  * vpopmail >= 5.4 dropped --enable-defaultquota / --enable-hardquota / --enable-default-domain:
      default quota -> default_quota in ${VPOPMAIL_DIR}/etc/vlimits.default
      default domain -> ${VPOPMAIL_DIR}/etc/defaultdomain
    this script writes them after make install (same as old 10MB quota + default domain)
  * vpopmail cdb/ subdir ignores CFLAGS; this script rewrites cdb/conf-cc after configure
  * services: /etc/init.d/smtp and /etc/init.d/pop3 (no systemd unit)
    TLS: /etc/init.d/smtps and /etc/init.d/pop3s
EOF
}

main "$@"
