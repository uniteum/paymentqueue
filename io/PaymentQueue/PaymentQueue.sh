#!/usr/bin/env bash
# PaymentQueue — Bitsy prototype of idempotent ERC-20 payout queues.
# No constructor args: the prototype is the implementation every queue clones and delegates to, and
# it owns nothing itself. Each queue is a clone, predicted and deployed from the repo that uses it.
set -euo pipefail
source "$(git rev-parse --show-toplevel)/lib/crucible/script/proto.sh"

# Optional vanity-mining metadata (uncomment and mine to land a branded address).
# mask=0xffff00000000000000000000000000000000ffff
# target=0x900e00000000000000000000000000000000e009

proto_predict PaymentQueue 0x0000000000000000000000000000000000000000000000000000000000000000
