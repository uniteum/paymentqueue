---
paths:
  - "lib/ipaymentqueue/**"
---

# Committed ABI

`lib/ipaymentqueue/IPaymentQueue.abi.json` is a generated file, committed
in ipaymentqueue so repos that depend on the interface can use the ABI
without a Solidity toolchain. The interface repo has no forge of its own,
so this repo is where the ABI is generated. Never edit it by hand.

Whenever `IPaymentQueue.sol` changes, regenerate it:

```bash
forge inspect IPaymentQueue abi --json > lib/ipaymentqueue/IPaymentQueue.abi.json
```

Commit it in the submodule together with the interface change, on a real
branch per [submodule.md](./submodule.md), then stage the bumped
submodule pointer here.
