#!/usr/bin/env bash
# =============================================================================
#  Pre-publish check: refuse to ship anything that looks like a real secret.
#  Run from the repo root before every push:   ./scripts/check-no-secrets.sh
# =============================================================================
set -uo pipefail
cd "$(dirname "$0")/.."

fail=0
report() { printf '  \033[1;31mFAIL\033[0m  %s\n' "$*"; fail=1; }
pass()   { printf '  \033[1;32mok\033[0m    %s\n' "$*"; }

echo "Scanning $(pwd) ..."

# 1. files that must never exist here
for f in .env docker-compose/.env vault-keys.txt docker-compose/vault-keys.txt \
         vault-init-raw.json; do
  [[ -e "$f" ]] && report "$f exists -- it holds live values" || true
done

# 2. placeholders must still be placeholders
if [[ -f docker-compose/.env.example ]]; then
  n=$(grep -c 'CHANGE_ME' docker-compose/.env.example || true)
  (( n >= 10 )) && pass ".env.example still has $n CHANGE_ME placeholders" \
                || report ".env.example has only $n placeholders -- real values may have crept in"
fi

# 3. credential-shaped strings
patterns=(
  'cfut_[A-Za-z0-9_-]{20,}'                 # Cloudflare API token
  'hvs\.[A-Za-z0-9_-]{20,}'                 # Vault token
  'AKIA[0-9A-Z]{16}'                        # AWS access key
  'gh[pousr]_[A-Za-z0-9]{30,}'              # GitHub token
  '-----BEGIN [A-Z ]*PRIVATE KEY-----'      # private key
  '"password":"[^"]{6,}"'                   # docker config
  'eyJhdXRocyI6'                            # base64 dockerconfigjson
)
for p in "${patterns[@]}"; do
  hits=$(grep -rEIl "$p" . --exclude-dir=.git --exclude=check-no-secrets.sh 2>/dev/null || true)
  [[ -n "$hits" ]] && report "pattern /$p/ in: $(echo "$hits" | tr '\n' ' ')"
done

# 4. long hex/base64 blobs that are not obviously placeholders
hits=$(grep -rEIn '[0-9a-fA-F]{40,}' . --exclude-dir=.git --exclude=check-no-secrets.sh 2>/dev/null \
       | grep -viE 'CHANGE_ME|example|sha256|checksum|digest' || true)
[[ -n "$hits" ]] && report "long hex strings (possible keys):" && echo "$hits" | head -5 | sed 's/^/        /'

# 5. internal hosts that should not be advertised
for h in 'stage\.authsec\.dev' 'k3s-authsec' '37\.27\.104\.185' '49\.12\.150\.218'; do
  hits=$(grep -rEIl "$h" . --exclude-dir=.git --exclude=check-no-secrets.sh 2>/dev/null || true)
  [[ -n "$hits" ]] && report "internal reference /$h/ in: $(echo "$hits" | tr '\n' ' ')"
done

echo
if (( fail )); then
  echo "  Do not publish until the above are resolved."
  exit 1
fi
echo "  Clean -- safe to publish."
