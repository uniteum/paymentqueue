#!/usr/bin/env bash
# USDCPaymentQueue3 — clone of PaymentQueue that pays in the chain-local Circle USDC. The token is
# the USDC AddressLookup, so the queue lands at the same address on every chain and zzInit resolves
# it to that chain's USDC. Same owner and lookup as USDCPaymentQueue2, made from the prototype that
# keeps a fee from each payment; the earlier queue stays as it was.
#
# PaymentQueue.encode(owner, token) is abi.encode(owner, token), and Prototype.made computes
#   salt = keccak(abi.encode(owner, token)) ^ variant
#
# Deps (hardcoded with provenance — update after re-running any upstream predict script):
#   deployer ← paymentqueue/io/PaymentQueue/   (same repo, the PaymentQueue prototype)
#   token    ← uniswap-lookup/io/USDC/         (sibling repo, the Circle-USDC AddressLookup)
set -euo pipefail
source "$(git rev-parse --show-toplevel)/lib/crucible/script/clone.sh"

deployer=0x1eE563EC966def14496481E1e5745022979F0868 # PaymentQueue

owner=0xD35164106638140589deFc863E7a9c38d5441748
token=0xC5DC3461ed6653dbC5E6A8bCDcF0354fF178E300 # USDC Lookup

# Optional vanity-mining metadata (uncomment and mine to land a branded address).
# mask=0xffff00000000000000000000000000000000ffff
# target=0x900e00000000000000000000000000000000e009

clone_predict USDCPaymentQueue3 "$deployer" \
    "address,address" "$owner" "$token" \
    0x0000000000000000000000000000000000000000000000000000000000000000
