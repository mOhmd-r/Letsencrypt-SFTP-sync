# Security policy

Report suspected vulnerabilities through GitHub's private vulnerability-reporting
flow rather than a public issue. Include the affected revision, prerequisites,
impact, and a minimal reproduction when possible.

Security fixes target the current default branch. This tool assumes trusted source
root, pinned SSH host keys, a dedicated restricted SSH identity, and controlled
remote sudo. Certificate archives and temporary data are secrets. SHA-256 protects
against accidental transfer corruption, not a source or destination compromise.
