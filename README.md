# Let's Encrypt SFTP Sync

Securely synchronize Let's Encrypt certificate material from one Linux host to one or more remote hosts over SSH/SFTP.

The project is designed for small infrastructure environments where certificates are issued or renewed on one node and must be copied to other nodes while preserving the normal Let's Encrypt directory structure.

## Highlights

- Transfers only `live/` and `archive/` by default. ACME account keys and DNS-provider credentials are never included.
- Uses **SFTP over SSH** for transport.
- Reuses a single SSH ControlMaster connection per target.
- Uses strict SSH host-key verification.
- Requires public-key SSH authentication; password and keyboard-interactive SSH login are disabled.
- Detects passwordless remote `sudo`.
- If remote `sudo` needs a password, reads it interactively from `/dev/tty`.
- Never stores the sudo password in a file or command-line argument.
- Creates a private temporary directory on each destination.
- Verifies the uploaded archive with SHA-256 before installation.
- Copies the upload into a root-owned staging area and verifies it again, closing the unprivileged-upload race.
- Rejects path traversal, special filesystem nodes, and symlinks that escape the staged tree.
- Validates every live certificate, private key, expiry, and public-key match before installation.
- Replaces the destination by same-filesystem rename and automatically rolls back on install or reload failure.
- Preserves Let's Encrypt symlinks and numeric ownership.
- Continues processing other hosts when one destination fails.
- Returns a non-zero exit code if any destination fails.

## Architecture

```text
Source host
/etc/letsencrypt
      |
      | allowlisted tar (live/ + archive/)
      v
Local private temporary archive
      |
      | SFTP over authenticated SSH
      v
Remote private /tmp upload
      |
      | root-owned copy + second SHA-256 check
      v
validated same-filesystem staging tree
      |
      | atomic rename + optional service reload
      v
/etc/letsencrypt
```

## Requirements

### Source

- Linux
- Bash
- OpenSSH client
- `tar`
- `gzip`
- `sha256sum`
- `mktemp`
- read access to `/etc/letsencrypt`

The script is normally executed with `sudo`.

### Destination

- SSH/SFTP server
- `sudo`
- `tar`
- `sha256sum`
- `mktemp`
- `realpath`
- `openssl`
- SSH user with permission to run `sudo`

## Installation

Clone the repository:

```bash
git clone https://github.com/mOhmd-r/Letsencrypt-SFTP-sync.git
cd letsencrypt-sftp-sync
```

Make the script executable:

```bash
chmod +x sync_cert.sh
```

Create your targets file:

```bash
cp examples/targets.example targets.txt
```

Edit it:

```text
dev@192.168.1.10:22
dev@192.168.1.11:22
dev@192.168.1.12:2222
```

Blank lines and lines beginning with `#` are ignored.

## SSH host-key verification

The script intentionally uses:

```text
StrictHostKeyChecking=yes
```

Targets must already exist in the configured `known_hosts` file.

Verify each host fingerprint through a trusted channel before adding it.

For a standard SSH port:

```bash
ssh-keyscan -H server.example.com >> ~/.ssh/known_hosts
```

For a non-standard port:

```bash
ssh-keyscan -H -p 2222 server.example.com >> ~/.ssh/known_hosts
```

`ssh-keyscan` alone does **not** prove the identity of the host. Verify the fingerprint independently before trusting it.

## Configuration

Defaults:

```bash
CERTS_DIR=/etc/letsencrypt
SSH_KEY=<invoking-sudo-user-home>/.ssh/id_ed25519
KNOWN_HOSTS=<invoking-sudo-user-home>/.ssh/known_hosts

SSH_CONNECT_TIMEOUT=10

SFTP_BUFFER_SIZE=65536
SFTP_REQUESTS=128

GZIP_LEVEL=9

# Optional: a validated systemd unit name, for example nginx.service
RELOAD_SERVICE=

# Optional; also transfer renewal/. accounts/ is never copied.
INCLUDE_RENEWAL_CONFIG=false
```

They can be overridden with environment variables:

```bash
sudo \
  SSH_KEY=/path/to/cert_sync \
  KNOWN_HOSTS=/path/to/known_hosts \
  RELOAD_SERVICE=nginx.service \
  ./sync_cert.sh targets.txt
```

## Run

```bash
sudo ./sync_cert.sh targets.txt
```

Example flow:

```text
🚀 Target: dev@server1:22
  🔑 Connecting...
  ✔ SSH connected
  🔐 Remote sudo password required
  sudo password for dev@server1:
  ✔ sudo password accepted
  ✔ Secure temporary directory created
  📤 Uploading via SFTP...
  ✔ SFTP upload completed
  🔎 Verifying SHA-256...
  ✔ SHA-256 verified
  🔎 Validating archive...
  ✔ Archive valid
  📦 Installing certificates...
  ✔ Certificates installed atomically
  ✔ Certificate/key pairs verified
  ✅ Sync completed successfully
```

## SFTP tuning

The defaults are deliberately conservative:

```bash
SFTP_BUFFER_SIZE=65536
SFTP_REQUESTS=128
```

A previous 256 KiB request size can fail on implementations with messages such as:

```text
Outbound message too long
```

Throughput is therefore improved primarily by increasing the number of outstanding SFTP requests instead of creating oversized individual packets.

If required:

```bash
sudo \
  SFTP_BUFFER_SIZE=65536 \
  SFTP_REQUESTS=64 \
  ./sync_cert.sh targets.txt
```

## Security model

### SSH host keys

Host-key verification is mandatory. The script does not use `StrictHostKeyChecking=accept-new`.

### SSH key

The configured private key must already be a regular, non-symlink file with no group or other access. The script never silently changes its permissions. The key and `known_hosts` must be owned by root or the invoking sudo user; `known_hosts` must not be group- or world-writable.

For production, using a dedicated certificate-sync SSH key is preferable to using a personal SSH identity.

### Agent forwarding

SSH agent forwarding is disabled:

```text
ForwardAgent=no
```

### Port forwarding

Unnecessary SSH forwarding is disabled:

```text
ClearAllForwardings=yes
```

### Remote sudo password

When passwordless sudo is unavailable, the password is read directly from `/dev/tty` with echo disabled.

The password is:

- not written to disk;
- not placed in shell history;
- not passed as a process argument;
- cleared from the shell variable after the target is processed.

It is passed to remote `sudo -S` through standard input.

### Temporary files

The source temporary directory is mode `0700`.

The archive is mode `0600`.

Each remote host receives a unique temporary directory created using:

```bash
umask 077
mktemp -d
```

The SFTP upload is never extracted with privilege. Root first copies it into a
private directory on the destination filesystem and verifies the expected hash
again. Validation and extraction occur there. The previous certificate tree is
renamed aside immediately before the staged tree is renamed into place. If an
optional systemd reload fails, the previous tree is restored and reloaded.

SHA-256 detects transfer corruption; it is not a signature. Security still
depends on the source host, SSH key, pinned host key, and remote root boundary.

The temporary directory is deleted after installation. Once certificate/key validation and the optional service reload succeed, the new tree is committed before old-tree cleanup; a cleanup error can therefore never roll back to partially deleted data.

### Integrity

The local SHA-256 digest is checked once as the SSH user after upload and again
against the root-owned copy before extraction.

### Archive validation

The uploaded archive is listed before extraction. Absolute and parent-directory
paths are rejected. After extraction, special nodes and escaping symlinks are
rejected, and each live certificate/key pair is cryptographically checked.

The basic archive readability check uses:

```bash
tar -tzf
```

before it is installed.

## Production recommendation

For higher-security production environments, consider replacing general remote sudo access with a tightly scoped root-owned deployment helper and a corresponding restricted sudoers rule.

That approach reduces the privilege available to the SSH account while keeping the SFTP transport architecture unchanged.

## What this project intentionally does not do

- It does not compare with the previous synchronization.
- It does not skip unchanged certificates.
- It does not perform incremental synchronization.
- It does not transfer Certbot renewal configuration unless `INCLUDE_RENEWAL_CONFIG=true` is explicitly set.
- It never transfers `accounts/` or other source-side top-level Certbot content, including DNS-provider credential files. Existing destination-local content outside the selected trees is preserved during the atomic replacement.
- It does not guess which service consumes the certificates; set the optional
  `RELOAD_SERVICE` systemd unit explicitly when an atomic reload is required.

Every execution transfers a complete snapshot of the selected allowlisted trees.

## Validation

Check syntax locally:

```bash
bash -n sync_cert.sh
```

If ShellCheck is installed:

```bash
shellcheck sync_cert.sh
```

## License

MIT
