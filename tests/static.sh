#!/usr/bin/env bash

set -Eeuo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_DIR"

rg -q -- '-o StrictHostKeyChecking=yes' sync_cert.sh
rg -q -- '-o PasswordAuthentication=no' sync_cert.sh
rg -q -- '-o KbdInteractiveAuthentication=no' sync_cert.sh
rg -q 'ssh-keygen -F' sync_cert.sh
rg -q 'install -o root -g root -m 600' sync_cert.sh
rg -q 'openssl x509 -checkend 0' sync_cert.sh
rg -q 'mv -- .*certs_dir.*old' sync_cert.sh
rg -q 'systemctl reload' sync_cert.sh
rg -Fq 'archive_members=(live archive)' sync_cert.sh
rg -q 'Preserve destination-local content' sync_cert.sh

cleanup_line="$(rg -n 'old tree cleanup failed' sync_cert.sh | cut -d: -f1)"
commit_line="$(rg -n '^[[:space:]]*installed=false$' sync_cert.sh | tail -n1 | cut -d: -f1)"
[[ -n "$cleanup_line" && -n "$commit_line" && "$commit_line" -lt "$cleanup_line" ]] || {
    printf 'Rollback must be disarmed before old-tree cleanup.\n' >&2
    exit 1
}

if rg -n 'StrictHostKeyChecking=(no|accept-new)' sync_cert.sh; then
    printf 'Unsafe SSH host-key policy found.\n' >&2
    exit 1
fi

printf 'Static security-policy tests passed.\n'
