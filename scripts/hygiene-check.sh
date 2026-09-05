#!/bin/zsh
# Public-repo hygiene: fail if tracked or untracked (non-ignored) files contain machine paths,
# personal identifiers or credentials. Run before committing; CI runs it too.
set -u
pattern='/Users/[a-z]|/home/[a-z]|Xcode-[0-9]|[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[a-z]{2,}|BEGIN (RSA|EC|OPENSSH|PGP) PRIVATE|AKIA[0-9A-Z]{16}|ghp_[A-Za-z0-9]{20,}|sk-[A-Za-z0-9]{20,}|DEVELOPMENT_TEAM = [A-Z0-9]{10}$|[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}'
allow='noreply@anthropic\.com|2ED6657D-E927-568B-95E1-2665A8AEA6A2|Configs/Local\.xcconfig\.example:.*YOURTEAMID|Tests/.*UUID\(uuidString|Sources/.*UUID\(uuidString|Package\.resolved'
hits=$(git ls-files --cached --others --exclude-standard | xargs grep -nIE "$pattern" 2>/dev/null | grep -vE "$allow")
if [ -n "$hits" ]; then
  echo "hygiene: suspicious content in tracked files:"; echo "$hits"; exit 1
fi
echo "hygiene: clean"
