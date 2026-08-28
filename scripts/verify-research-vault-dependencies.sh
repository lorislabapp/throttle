#!/bin/sh
set -eu

repo="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
package="$repo/Packages/ResearchVaultKit"
manifest_json="$(mktemp -t research-vault-package.XXXXXX)"
throttle_target="$(mktemp -t research-vault-throttle-target.XXXXXX)"
module_cache="$package/.build/verification-manifest-module-cache"
trap 'rm -f "$manifest_json" "$throttle_target"' EXIT HUP INT TERM

mkdir -p "$module_cache"
CLANG_MODULE_CACHE_PATH="$module_cache" \
SWIFTPM_MODULECACHE_OVERRIDE="$module_cache" \
swift package --package-path "$package" dump-package > "$manifest_json"

jq -e '
  . as $package
  | def direct($name): [
      $package.targets[]
      | select(.name == $name)
      | .dependencies[]?
      | (.byName[0]? // .target[0]? // .product[0]?)
    ];
  reduce range(0; ($package.targets | length)) as $iteration
    (["ResearchVaultXPCClient"];
      . as $known | (($known + [$known[] | direct(.)[]]) | unique)
    )
  | . as $closure
  | (["ResearchVaultGateway", "ResearchVaultSQLCipher", "ResearchVaultStore",
      "ResearchVaultKeychain", "ResearchVaultIngestion", "SQLCipher"]
      | map(select(. as $forbidden | $closure | index($forbidden)))) as $violations
  | if ($violations | length) == 0 then true
    else error("client dependency closure contains forbidden targets: \($violations)")
    end
' "$manifest_json" > /dev/null

awk '
  /^  Throttle:$/ { inside = 1 }
  /^  ResearchVaultAgent:$/ { inside = 0 }
  inside { print }
' "$repo/project.yml" > "$throttle_target"

grep -q 'product: ResearchVaultIPCModel' "$throttle_target"
grep -q 'product: ResearchVaultXPCClient' "$throttle_target"
if grep -Eq 'product: (ResearchVaultXPC|ResearchVaultGateway|ResearchVaultSQLCipher|ResearchVaultStore|ResearchVaultKeychain|ResearchVaultIngestion)$' "$throttle_target"; then
    echo "Throttle target links a server-side Research Vault product" >&2
    exit 1
fi

echo '{"status":"pass","scenario":"research-vault-client-dependency-boundary"}'
