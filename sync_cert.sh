#!/usr/bin/env bash

set -Eeuo pipefail

# ============================================================
# Let's Encrypt SFTP Certificate Sync
# ============================================================

CERTS_DIR="${CERTS_DIR:-/etc/letsencrypt}"

INVOKING_USER="${SUDO_USER:-root}"
INVOKING_HOME="$(getent passwd "$INVOKING_USER" 2>/dev/null | cut -d: -f6 || true)"
SSH_KEY="${SSH_KEY:-${INVOKING_HOME}/.ssh/id_ed25519}"
KNOWN_HOSTS="${KNOWN_HOSTS:-${INVOKING_HOME}/.ssh/known_hosts}"

SSH_CONNECT_TIMEOUT="${SSH_CONNECT_TIMEOUT:-10}"

# SFTP tuning.
# 64 KiB keeps each request comfortably below common packet limits.
SFTP_BUFFER_SIZE="${SFTP_BUFFER_SIZE:-65536}"
SFTP_REQUESTS="${SFTP_REQUESTS:-128}"

# Strong compression is useful when the network is slower than local CPU.
GZIP_LEVEL="${GZIP_LEVEL:-9}"
RELOAD_SERVICE="${RELOAD_SERVICE:-}"
INCLUDE_RENEWAL_CONFIG="${INCLUDE_RENEWAL_CONFIG:-false}"

IPS_FILE="${1:-}"

TMP_DIR=""
ARCHIVE=""
ARCHIVE_SHA256=""
CONTROL_SOCKET=""

SUDO_MODE=""
SUDO_PASSWORD=""

SUCCESS=0
FAILED=0

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

cleanup() {
    unset SUDO_PASSWORD

    if [[ -n "${TMP_DIR:-}" && -d "$TMP_DIR" ]]; then
        rm -rf -- "$TMP_DIR"
    fi
}

trap cleanup EXIT
trap 'echo; echo "Interrupted."; exit 130' INT TERM

usage() {
    cat <<EOF

Usage:
  sudo $0 <targets_file>

Target format:
  user@host:port

Example:
  dev@192.168.1.10:22
  dev@192.168.1.11:2222

Optional environment overrides:
  CERTS_DIR
  SSH_KEY
  KNOWN_HOSTS
  SSH_CONNECT_TIMEOUT
  SFTP_BUFFER_SIZE
  SFTP_REQUESTS
  GZIP_LEVEL
  INCLUDE_RENEWAL_CONFIG  false by default; true also transfers renewal/
  RELOAD_SERVICE        Optional systemd unit reloaded after an atomic swap

EOF
}

SSH_OPTIONS=(
    -i "$SSH_KEY"
    -o IdentitiesOnly=yes
    -o StrictHostKeyChecking=yes
    -o UserKnownHostsFile="$KNOWN_HOSTS"
    -o ConnectTimeout="$SSH_CONNECT_TIMEOUT"
    -o ServerAliveInterval=15
    -o ServerAliveCountMax=3
    -o TCPKeepAlive=yes
    -o Compression=no
    -o IPQoS=throughput
    -o ForwardAgent=no
    -o ClearAllForwardings=yes
    -o BatchMode=yes
    -o PasswordAuthentication=no
    -o KbdInteractiveAuthentication=no
    -o PreferredAuthentications=publickey
)

open_ssh_connection() {
    local target="$1"
    local port="$2"
    local socket_id

    socket_id="$(printf '%s' "$target-$port" | sha256sum | cut -c1-16)"
    CONTROL_SOCKET="$TMP_DIR/control-$socket_id"

    rm -f -- "$CONTROL_SOCKET"

    ssh \
        "${SSH_OPTIONS[@]}" \
        -o ControlMaster=yes \
        -o ControlPersist=120 \
        -o ControlPath="$CONTROL_SOCKET" \
        -p "$port" \
        -Nf \
        "$target"
}

close_ssh_connection() {
    local target="$1"
    local port="$2"

    [[ -n "${CONTROL_SOCKET:-}" ]] || return 0

    ssh \
        -S "$CONTROL_SOCKET" \
        -O exit \
        -p "$port" \
        "$target" \
        >/dev/null 2>&1 || true

    rm -f -- "$CONTROL_SOCKET" 2>/dev/null || true
    CONTROL_SOCKET=""
}

remote_ssh() {
    local target="$1"
    local port="$2"
    shift 2

    ssh \
        -T \
        -S "$CONTROL_SOCKET" \
        -o ControlMaster=no \
        -p "$port" \
        "$target" \
        "$@"
}

setup_remote_sudo() {
    local target="$1"
    local port="$2"

    SUDO_MODE=""
    SUDO_PASSWORD=""

    if remote_ssh "$target" "$port" "sudo -n true" >/dev/null 2>&1; then
        SUDO_MODE="nopasswd"
        echo "  ✔ sudo available without password"
        return 0
    fi

    SUDO_MODE="password"

    echo -e "  ${YELLOW}🔐 Remote sudo password required${NC}"

    if [[ ! -r /dev/tty ]]; then
        echo -e "  ${RED}❌ Interactive terminal unavailable${NC}"
        return 1
    fi

    read \
        -r \
        -s \
        -p "  sudo password for $target: " \
        SUDO_PASSWORD \
        < /dev/tty

    echo

    if printf '%s\n' "$SUDO_PASSWORD" |
        remote_ssh "$target" "$port" \
            "sudo -k -S -p '' true" \
            >/dev/null 2>&1; then

        echo "  ✔ sudo password accepted"
        return 0
    fi

    echo -e "  ${RED}❌ sudo authentication failed${NC}"

    unset SUDO_PASSWORD
    SUDO_MODE=""

    return 1
}

remote_sudo() {
    local target="$1"
    local port="$2"
    local command="$3"

    case "$SUDO_MODE" in
        nopasswd)
            remote_ssh \
                "$target" \
                "$port" \
                "sudo -n bash -c $(printf '%q' "$command")"
            ;;

        password)
            printf '%s\n' "$SUDO_PASSWORD" |
                remote_ssh \
                    "$target" \
                    "$port" \
                    "sudo -S -p '' bash -c $(printf '%q' "$command")"
            ;;

        *)
            echo "Internal error: sudo mode not configured"
            return 1
            ;;
    esac
}

sftp_upload() {
    local target="$1"
    local port="$2"
    local local_file="$3"
    local remote_file="$4"

    printf 'put "%s" "%s"\nchmod 600 "%s"\n' \
        "$local_file" \
        "$remote_file" \
        "$remote_file" |
    sftp \
        -b - \
        -B "$SFTP_BUFFER_SIZE" \
        -R "$SFTP_REQUESTS" \
        -o BatchMode=yes \
        -o ControlMaster=no \
        -o ControlPath="$CONTROL_SOCKET" \
        -o Compression=no \
        -P "$port" \
        "$target"
}

sync_host() {
    local line="$1"

    local user
    local hostport
    local host
    local port
    local target
    local host_lookup

    local remote_tmp_dir
    local remote_archive
    local remote_sha256

    SUDO_MODE=""
    SUDO_PASSWORD=""
    CONTROL_SOCKET=""

    if [[ ! "$line" =~ ^[A-Za-z_][A-Za-z0-9._-]*@[A-Za-z0-9._-]+:[0-9]+$ ]]; then
        echo -e "${RED}❌ Invalid target:${NC} $line"
        echo "   Expected: user@host:port"
        return 1
    fi

    user="${line%@*}"
    hostport="${line#*@}"
    host="${hostport%%:*}"
    port="${hostport##*:}"
    if (( port < 1 || port > 65535 )); then
        echo -e "${RED}❌ Invalid SSH port:${NC} $port"
        return 1
    fi
    target="$user@$host"
    host_lookup="$host"
    [[ "$port" == "22" ]] || host_lookup="[$host]:$port"

    if ! ssh-keygen -F "$host_lookup" -f "$KNOWN_HOSTS" >/dev/null; then
        echo -e "${RED}❌ No pinned host key for:${NC} $host_lookup"
        return 1
    fi

    echo
    echo "============================================================"
    echo -e "${BLUE}🚀 Target: $target:$port${NC}"
    echo "============================================================"

    echo "  🔑 Connecting..."

    if ! open_ssh_connection "$target" "$port"; then
        echo -e "  ${RED}❌ SSH connection failed${NC}"
        return 1
    fi

    echo "  ✔ SSH connected"

    if ! remote_ssh "$target" "$port" \
        "command -v sudo >/dev/null &&
         command -v tar >/dev/null &&
         command -v sha256sum >/dev/null &&
         command -v mktemp >/dev/null &&
         command -v realpath >/dev/null &&
         command -v openssl >/dev/null"; then

        echo -e "  ${RED}❌ Required remote commands are missing${NC}"
        close_ssh_connection "$target" "$port"
        return 1
    fi

    if ! setup_remote_sudo "$target" "$port"; then
        close_ssh_connection "$target" "$port"
        return 1
    fi

    remote_tmp_dir="$(
        remote_ssh \
            "$target" \
            "$port" \
            "umask 077; mktemp -d /tmp/letsencrypt-sync.XXXXXXXX"
    )"

    if [[ ! "$remote_tmp_dir" =~ ^/tmp/letsencrypt-sync\.[A-Za-z0-9]+$ ]]; then
        echo -e "  ${RED}❌ Invalid remote temporary path${NC}"

        unset SUDO_PASSWORD
        close_ssh_connection "$target" "$port"

        return 1
    fi

    remote_archive="$remote_tmp_dir/letsencrypt.tar.gz"

    echo "  ✔ Secure temporary directory created"

    echo "  📤 Uploading via SFTP..."

    if ! sftp_upload \
        "$target" \
        "$port" \
        "$ARCHIVE" \
        "$remote_archive"; then

        echo -e "  ${RED}❌ SFTP upload failed${NC}"

        remote_ssh \
            "$target" \
            "$port" \
            "rm -rf -- '$remote_tmp_dir'" \
            >/dev/null 2>&1 || true

        unset SUDO_PASSWORD
        close_ssh_connection "$target" "$port"

        return 1
    fi

    echo "  ✔ SFTP upload completed"

    echo "  🔎 Verifying SHA-256..."

    remote_sha256="$(
        remote_ssh \
            "$target" \
            "$port" \
            "sha256sum '$remote_archive' | awk '{print \$1}'"
    )"

    if [[ "$ARCHIVE_SHA256" != "$remote_sha256" ]]; then
        echo -e "  ${RED}❌ SHA-256 mismatch${NC}"
        echo "     Local : $ARCHIVE_SHA256"
        echo "     Remote: $remote_sha256"

        remote_ssh \
            "$target" \
            "$port" \
            "rm -rf -- '$remote_tmp_dir'" \
            >/dev/null 2>&1 || true

        unset SUDO_PASSWORD
        close_ssh_connection "$target" "$port"

        return 1
    fi

    echo "  ✔ SHA-256 verified"

    echo "  🔎 Validating archive..."

    if ! remote_ssh \
        "$target" \
        "$port" \
        "tar -tzf '$remote_archive' >/dev/null"; then

        echo -e "  ${RED}❌ Remote archive is invalid${NC}"

        remote_ssh \
            "$target" \
            "$port" \
            "rm -rf -- '$remote_tmp_dir'" \
            >/dev/null 2>&1 || true

        unset SUDO_PASSWORD
        close_ssh_connection "$target" "$port"

        return 1
    fi

    echo "  ✔ Archive valid"

    echo "  📦 Installing certificates..."

    local certs_q archive_q hash_q reload_q
    printf -v certs_q '%q' "$CERTS_DIR"
    printf -v archive_q '%q' "$remote_archive"
    printf -v hash_q '%q' "$ARCHIVE_SHA256"
    printf -v reload_q '%q' "$RELOAD_SERVICE"

    if ! remote_sudo \
        "$target" \
        "$port" \
        "
        set -Eeuo pipefail
        umask 077
        certs_dir=$certs_q
        source_archive=$archive_q
        expected_hash=$hash_q
        reload_service=$reload_q
        parent=\$(dirname \"\$certs_dir\")
        base=\$(basename \"\$certs_dir\")
        work=\$(mktemp -d \"\${parent}/.\${base}.work.XXXXXXXX\")
        stage=\$(mktemp -d \"\${parent}/.\${base}.stage.XXXXXXXX\")
        root_archive=\"\$work/source.tar.gz\"
        old=\"\${parent}/.\${base}.previous.\$\$\"
        installed=false
        had_previous=false

        rollback() {
            status=\$?
            if [[ \$status -ne 0 && \"\$installed\" == true ]]; then
                rm -rf -- \"\$certs_dir\"
                if [[ \"\$had_previous\" == true && -d \"\$old\" && ! -L \"\$old\" ]]; then
                    mv -- \"\$old\" \"\$certs_dir\" || true
                fi
                if [[ \"\$had_previous\" == true && -n \"\$reload_service\" ]]; then
                    systemctl reload \"\$reload_service\" >/dev/null 2>&1 || true
                fi
            fi
            [[ -e \"\$stage\" ]] && rm -rf -- \"\$stage\"
            [[ -e \"\$work\" ]] && rm -rf -- \"\$work\"
            exit \$status
        }
        trap rollback EXIT

        install -o root -g root -m 600 -- \"\$source_archive\" \"\$root_archive\"
        printf '%s  %s\\n' \"\$expected_hash\" source.tar.gz > \"\$work/SHA256SUMS\"
        (cd \"\$work\" && sha256sum --strict -c SHA256SUMS)

        while IFS= read -r member; do
            [[ \"\$member\" != /* ]] || exit 41
            case \"/\$member/\" in */../*) exit 42 ;; esac
        done < <(tar -tzf \"\$root_archive\")

        # Preserve destination-local content (for example ACME account state
        # and provider credentials) without ever transferring it from source.
        if [[ -e \"\$certs_dir\" ]]; then
            [[ -d \"\$certs_dir\" && ! -L \"\$certs_dir\" ]]
            cp -a -- \"\$certs_dir/.\" \"\$stage/\"
        fi
        rm -rf -- \"\$stage/live\" \"\$stage/archive\"
        if [[ "$INCLUDE_RENEWAL_CONFIG" == true ]]; then
            rm -rf -- \"\$stage/renewal\"
        fi
        tar -xzf \"\$root_archive\" -C \"\$stage\" --no-same-owner --same-permissions
        chmod -R u-s,g-s \"\$stage\"
        rm -rf -- \"\$work\"
        work=''

        test -d \"\$stage/live\"
        test -d \"\$stage/archive\"
        if [[ "$INCLUDE_RENEWAL_CONFIG" == true ]]; then
            test -d \"\$stage/renewal\"
        else
            test ! -e \"\$stage/renewal\"
        fi
        unexpected=\$(find \"\$stage\" ! -type f ! -type d ! -type l -print -quit)
        [[ -z \"\$unexpected\" ]]
        while IFS= read -r link; do
            resolved=\$(realpath -m \"\$link\")
            case \"\$resolved\" in \"\$stage\"/*) ;; *) exit 43 ;; esac
        done < <(find \"\$stage\" -type l -print)

        found_certificate=false
        for fullchain in \"\$stage\"/live/*/fullchain.pem; do
            [[ -e \"\$fullchain\" ]] || continue
            found_certificate=true
            cert_dir=\$(dirname \"\$fullchain\")
            privkey=\"\$cert_dir/privkey.pem\"
            test -f \"\$fullchain\"
            test -f \"\$privkey\"
            openssl x509 -checkend 0 -noout -in \"\$fullchain\" >/dev/null
            openssl pkey -check -noout -in \"\$privkey\" >/dev/null
            cert_pub=\$(openssl x509 -in \"\$fullchain\" -pubkey -noout | openssl pkey -pubin -outform DER 2>/dev/null | sha256sum)
            key_pub=\$(openssl pkey -in \"\$privkey\" -pubout -outform DER 2>/dev/null | sha256sum)
            [[ \"\${cert_pub%% *}\" == \"\${key_pub%% *}\" ]]
        done
        [[ \"\$found_certificate\" == true ]]

        if [[ -e \"\$certs_dir\" ]]; then
            [[ -d \"\$certs_dir\" && ! -L \"\$certs_dir\" ]]
            [[ ! -e \"\$old\" ]]
            mv -- \"\$certs_dir\" \"\$old\"
            had_previous=true
        fi
        mv -- \"\$stage\" \"\$certs_dir\"
        stage=''
        installed=true
        if [[ -n \"\$reload_service\" ]]; then
            systemctl reload \"\$reload_service\"
        fi
        # Validation and reload succeeded. Commit before pruning the old tree so
        # cleanup failure cannot restore partially deleted data.
        installed=false
        trap - EXIT
        if [[ -n \"\$old\" && -e \"\$old\" ]] && ! rm -rf -- \"\$old\"; then
            printf 'WARNING: installed certificates are active, but old tree cleanup failed: %s\\n' \"\$old\" >&2
        fi
        "; then

        echo -e "  ${RED}❌ Certificate installation failed${NC}"

        remote_ssh \
            "$target" \
            "$port" \
            "rm -rf -- '$remote_tmp_dir'" \
            >/dev/null 2>&1 || true

        unset SUDO_PASSWORD
        close_ssh_connection "$target" "$port"

        return 1
    fi

    echo "  ✔ Certificates installed atomically"
    echo "  ✔ Certificate/key pairs verified"

    remote_ssh \
        "$target" \
        "$port" \
        "rm -rf -- '$remote_tmp_dir'" \
        >/dev/null 2>&1 || true

    unset SUDO_PASSWORD
    SUDO_MODE=""

    close_ssh_connection "$target" "$port"

    echo -e "  ${GREEN}✅ Sync completed successfully${NC}"

    return 0
}

if [[ $# -ne 1 ]]; then
    usage
    exit 1
fi

if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}❌ Run this script with sudo.${NC}"
    echo
    echo "  sudo $0 $IPS_FILE"
    exit 1
fi

if [[ ! -f "$IPS_FILE" ]]; then
    echo -e "${RED}❌ Targets file not found:${NC}"
    echo "  $IPS_FILE"
    exit 1
fi

if [[ ! -r "$IPS_FILE" ]]; then
    echo -e "${RED}❌ Cannot read targets file:${NC}"
    echo "  $IPS_FILE"
    exit 1
fi

if [[ ! "$CERTS_DIR" =~ ^/[A-Za-z0-9._/-]+$ || "$CERTS_DIR" == *..* || "$CERTS_DIR" == "/" || ! -d "$CERTS_DIR" || -L "$CERTS_DIR" ]]; then
    echo -e "${RED}❌ Let's Encrypt directory not found:${NC}"
    echo "  $CERTS_DIR"
    exit 1
fi

if [[ ! -f "$SSH_KEY" || -L "$SSH_KEY" ]]; then
    echo -e "${RED}❌ SSH private key not found:${NC}"
    echo "  $SSH_KEY"
    exit 1
fi

if [[ ! -f "$KNOWN_HOSTS" || -L "$KNOWN_HOSTS" ]]; then
    echo -e "${RED}❌ SSH known_hosts not found:${NC}"
    echo "  $KNOWN_HOSTS"
    echo
    echo "Target host keys must be verified and added before running."
    exit 1
fi

[[ -z "$RELOAD_SERVICE" || "$RELOAD_SERVICE" =~ ^[A-Za-z0-9_.@-]+$ ]] || {
    echo -e "${RED}❌ Invalid systemd unit name: $RELOAD_SERVICE${NC}"
    exit 1
}
[[ "$INCLUDE_RENEWAL_CONFIG" == "true" || "$INCLUDE_RENEWAL_CONFIG" == "false" ]] || {
    echo -e "${RED}❌ INCLUDE_RENEWAL_CONFIG must be true or false.${NC}"
    exit 1
}
[[ -n "$INVOKING_HOME" ]] || {
    echo -e "${RED}❌ Could not determine the invoking user's home directory; set SSH_KEY and KNOWN_HOSTS explicitly.${NC}"
    exit 1
}

for cmd in ssh sftp ssh-keygen tar gzip sha256sum mktemp stat; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo -e "${RED}❌ Required command missing: $cmd${NC}"
        exit 1
    fi
done

key_owner="$(stat -c '%u' "$SSH_KEY")"
known_hosts_owner="$(stat -c '%u' "$KNOWN_HOSTS")"
[[ "$key_owner" == "0" || -n "${SUDO_UID:-}" && "$key_owner" == "$SUDO_UID" ]] || {
    echo -e "${RED}❌ SSH key must be owned by root or the invoking sudo user.${NC}"
    exit 1
}
[[ "$known_hosts_owner" == "0" || -n "${SUDO_UID:-}" && "$known_hosts_owner" == "$SUDO_UID" ]] || {
    echo -e "${RED}❌ known_hosts must be owned by root or the invoking sudo user.${NC}"
    exit 1
}
(( (8#$(stat -c '%a' "$SSH_KEY") & 8#077) == 0 )) || {
    echo -e "${RED}❌ SSH private key must not be accessible by group or others.${NC}"
    exit 1
}
(( (8#$(stat -c '%a' "$KNOWN_HOSTS") & 8#022) == 0 )) || {
    echo -e "${RED}❌ known_hosts must not be group- or world-writable.${NC}"
    exit 1
}

TMP_DIR="$(mktemp -d)"
chmod 700 "$TMP_DIR"

ARCHIVE="$TMP_DIR/letsencrypt.tar.gz"

echo
echo "============================================================"
echo " Let's Encrypt Certificate Synchronization"
echo "============================================================"
echo

echo "📦 Creating certificate archive..."

archive_members=(live archive)
for required_tree in "${archive_members[@]}"; do
    [[ -d "${CERTS_DIR}/${required_tree}" && ! -L "${CERTS_DIR}/${required_tree}" ]] || {
        echo -e "${RED}❌ Required certificate tree is missing or symlinked: ${CERTS_DIR}/${required_tree}${NC}"
        exit 1
    }
done
if [[ "$INCLUDE_RENEWAL_CONFIG" == "true" ]]; then
    [[ -d "${CERTS_DIR}/renewal" && ! -L "${CERTS_DIR}/renewal" ]] || {
        echo -e "${RED}❌ Renewal configuration tree is missing or symlinked.${NC}"
        exit 1
    }
    archive_members+=(renewal)
fi

tar -C "$CERTS_DIR" -cf - -- "${archive_members[@]}" |
gzip "-$GZIP_LEVEL" > "$ARCHIVE"

while IFS= read -r member; do
    [[ "$member" != /* ]] || { echo -e "${RED}❌ Archive contains an absolute path.${NC}"; exit 1; }
    case "/$member/" in */../*) echo -e "${RED}❌ Archive contains a parent path.${NC}"; exit 1 ;; esac
done < <(tar -tzf "$ARCHIVE")

chmod 600 "$ARCHIVE"

ARCHIVE_SHA256="$(sha256sum "$ARCHIVE" | awk '{print $1}')"
ARCHIVE_SIZE="$(du -h "$ARCHIVE" | awk '{print $1}')"

echo "  ✔ Archive created"
echo "  ✔ Size: $ARCHIVE_SIZE"
echo "  ✔ SHA-256: $ARCHIVE_SHA256"
echo
echo "Transfer mode:"
echo "  SFTP"
echo
echo "SFTP buffer:"
echo "  $SFTP_BUFFER_SIZE bytes"
echo
echo "Outstanding SFTP requests:"
echo "  $SFTP_REQUESTS"
echo

while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"

    [[ -z "${line//[[:space:]]/}" ]] && continue
    [[ "$line" =~ ^[[:space:]]*# ]] && continue

    if sync_host "$line"; then
        ((SUCCESS += 1))
    else
        ((FAILED += 1))
    fi
done < "$IPS_FILE"

echo
echo "============================================================"
echo " Synchronization Summary"
echo "============================================================"
echo

echo -e "  Successful : ${GREEN}$SUCCESS${NC}"
echo -e "  Failed     : ${RED}$FAILED${NC}"
echo

if (( FAILED > 0 )); then
    echo -e "${RED}❌ Certificate synchronization completed with errors.${NC}"
    exit 1
fi

echo -e "${GREEN}🎉 All certificates synchronized successfully.${NC}"
