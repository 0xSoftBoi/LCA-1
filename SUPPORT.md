# Support boundary

LCA-1 is a pre-production research program. There is no SLA, production
deployment support, security certification, binary compatibility commitment,
or guaranteed hardware target.

Use GitHub issues for reproducible non-sensitive defects and proposals. Use the
private process in `SECURITY.md` for vulnerabilities. Questions should name the
commit, command, host/tool versions, expected result, actual result, and a
minimal reproducer.

The supported development path is the latest `main` branch with the toolchain
declared in `package-lock.json` and `.github/workflows/ci.yml`. CI artifacts
expire and are evidence for their exact commit, not standing performance
claims.
