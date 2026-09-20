# Let's Encrypt SFTP Sync

Securely synchronize a complete `/etc/letsencrypt` tree from one Linux host to one or more remote hosts over SSH/SFTP.

The project is designed for small infrastructure environments where certificates are issued or renewed on one node and must be copied to other nodes while preserving the normal Let's Encrypt directory structure.

## Highlights

- Transfers the complete `/etc/letsencrypt` directory on every run.
- Uses **SFTP over SSH** for transport.
- Reuses a single SSH ControlMaster connection per target.
- Uses strict SSH host-key verification.
- Supports SSH key authentication with normal OpenSSH password fallback.
- Detects passwordless remote `sudo`.
- If remote `sudo` needs a password, reads it interactively from `/dev/tty`.
- Never stores the sudo password in a file or command-line argument.
- Creates a private temporary directory on each destination.
- Verifies the uploaded archive with SHA-256 before installation.
- Validates the gzip/tar archive before touching `/etc/letsencrypt`.
- Preserves Let's Encrypt symlinks and numeric ownership.
- Continues processing other hosts when one destination fails.
- Returns a non-zero exit code if any destination fails.

## Architecture

```text
Source host
/etc/letsencrypt
      |
      | tar + gzip
      v
Local private temporary archive
      |
      | SFTP over authenticated SSH
      v
Remote private /tmp directory
      |
      | SHA-256 + tar validation
      v
Remote sudo
      |
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
- SSH user with permission to run `sudo`

## Installation

Clone the repository:

```bash
git clone https://github.com/YOUR-USER/letsencrypt-sftp-sync.git
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
SSH_KEY=/home/dev/.ssh/id_ed25519
KNOWN_HOSTS=/home/dev/.ssh/known_hosts

SSH_CONNECT_TIMEOUT=10

SFTP_BUFFER_SIZE=65536
SFTP_REQUESTS=128

GZIP_LEVEL=9
```

They can be overridden with environment variables:

```bash
sudo \
  SSH_KEY=/home/dev/.ssh/cert_sync \
  KNOWN_HOSTS=/home/dev/.ssh/known_hosts \
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
  ✔ Certificates installed
  ✔ Let's Encrypt structure verified
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

The configured private key is forced to mode `0600` before use.

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

The directory is deleted after installation.

### Integrity

The local SHA-256 digest is compared with the uploaded archive before extraction.

### Archive validation

The uploaded archive is tested with:

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
- It does not modify Certbot renewal configuration.
- It does not automatically reload Nginx, HAProxy, Kamailio, or other services.

Every execution transfers the complete Let's Encrypt archive.

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
