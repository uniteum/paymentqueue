#!/usr/bin/env bash
# USDCPaymentQueue — clone of PaymentQueue that pays in the chain-local Circle USDC. The token is
# the USDC AddressLookup, so the queue lands at the same address on every chain and zzInit resolves
# it to that chain's USDC.
#
# PaymentQueue.encode(owner, token) is abi.encode(owner, token), and Prototype.made computes
#   salt = keccak(abi.encode(owner, token)) ^ variant
#
# Deps (hardcoded with provenance — update after re-running any upstream predict script):
#   deployer ← paymentqueue/io/PaymentQueue/   (same repo, the PaymentQueue prototype)
#   token    ← uniswap-lookup/io/USDC/         (sibling repo, the Circle-USDC AddressLookup)
set -euo pipefail
source "$(git rev-parse --show-toplevel)/lib/crucible/script/clone.sh"

deployer=0xd043b5804E417f146CA886D7b9eA20F0e85A1e02 # PaymentQueue

owner=0x9891e323517761F525e55817F1b3fa2C52620b78
token=0xC5DC3461ed6653dbC5E6A8bCDcF0354fF178E300 # USDC Lookup

# Optional vanity-mining metadata (uncomment and mine to land a branded address).
# mask=0xffff00000000000000000000000000000000ffff
# target=0x900e00000000000000000000000000000000e009

clone_predict USDCPaymentQueue "$deployer" \
    "address,address" "$owner" "$token" \
    0x0000000000000000000000000000000000000000000000000000000000000000
