# PaymentQueue

> Idempotent ERC-20 payout queues, made by anyone for themselves. Pay each id once, hold what the
> float cannot cover, and never let one refused transfer block the rest.

A queue pays out a single ERC-20 token from a float that anyone can top up. Its owner submits each
payment under an **id of its own choosing**, and that id is the idempotency key: the first `pay` for
an id fixes its recipient and amount, and every later `pay` for it does nothing. An off-chain system
that loses a response, retries, or runs twice cannot pay twice, and needs no record of its own to
make that true — the guarantee is chain state.

The fit is any payout where something off-chain decides who is owed, the same instruction may arrive
more than once, and the float can run short: batch payouts keyed by an external id, withdrawal
queues keyed by a withdrawal id, claims keyed by a claim id, or bridge exits keyed by a source-chain
message id.

## How it works

**Pay.** `pay(id, recipient, amount)`, owner only. With nothing waiting and float enough to cover it,
the queue transfers at once and records the id `Paid`. Otherwise the payment joins the back of the
line as `Queued` — a new payment never passes one already waiting.

**Sweep.** `processPayments(limit)` is permissionless. It pays waiting payments oldest first while
the float covers the next one, stops at the first it cannot cover, and settles no more than `limit`,
so its gas is bounded by the caller. Simulating the call says how many it would settle, so nobody
need spend gas on a sweep that would do nothing.

**Refusal.** A transfer the token refuses — USDC refuses a blacklisted recipient, older tokens return
`false` — records that id `Failed` and moves on. A refused payment never blocks the payments behind
it, and its amount stays in the float. A `Failed` id is spent: submitting it again does nothing.

**Status.** `statusOf(id)` is `Unknown`, `Queued`, `Paid` or `Failed`, and `queued()` counts what is
waiting. `pay` returns the id's status, so simulating it previews the outcome.

**Float.** Anyone can send the token to a queue. `withdraw(to, amount)` takes it back out, owner
only. Native currency is refused rather than stranded.

### Accepted limits

One token per queue. FIFO only: no priority, no cancellation, no expiry, no partial payment. A
waiting payment the float cannot cover holds up those behind it — honest ordering, at the cost of
head-of-line blocking. One owner, fixed.

## Architecture

PaymentQueue is a [Bitsy](https://uniteum.one/bitsy/) prototype. The deployed contract is an inert
factory: it has no owner, no token and no float, and pays nothing. Each queue is an EIP-1167 clone of
it, made by whoever wants one:

```solidity
IPaymentQueue queue = prototype.make(token, 0);   // the caller owns it, for good
```

A queue's address is derived from its owner and token, so `made(owner, token, variant)` names it
before it exists, and making it again returns the same queue. Owner and token are set once, by
`zzInit`, which only the prototype can call. `variant` is a vanity-mining input; pass 0 for the
canonical address.

Two protections are worth knowing about, because both are easy to leave out:

- **The queue is `nonReentrant`.** Against a token with transfer hooks, a recipient can otherwise
  re-enter a sweep partway through its own payment and be paid repeatedly, draining the float.
- **A starved transfer is not a refusal.** `trySafeTransfer` cannot tell "the token refused" from
  "the transfer ran out of gas", and EIP-150 keeps back 1/64 of the caller's gas. For a token whose
  transfer costs more than roughly 140k gas, a sweep sent with a chosen gas limit could otherwise
  finish without the transfer and record a payable payment as `Failed`. A failed transfer that leaves
  less than that remainder reverts with `TransferOutOfGas` and records nothing.

## Installation

```bash
forge install uniteum/paymentqueue
```

To call a queue you only need the interface, [ipaymentqueue](https://github.com/uniteum/ipaymentqueue).

## Usage

```solidity
import {IPaymentQueue} from "ipaymentqueue/IPaymentQueue.sol";

IPaymentQueue queue = prototype.make(token, 0);

// Fund it: any transfer of the token to the queue's address will do.
token.transfer(address(queue), 1_000e6);

// Pay once per id, whatever happened to the call before.
IPaymentQueue.Status status = queue.pay(uint256(keccak256("invoice-4718")), alice, 25e6);

// Anyone can sweep what is waiting.
queue.processPayments(10);
```

## Testing

```bash
forge test
```

42 tests: the queue's behaviour against a well-behaved token, refusals by revert and by `false`
return, a recipient that re-enters the sweep, a gas-starved sweep scanned across gas limits, how
queues are made, the four cases carried over from the v1 contract this replaces, a fuzz test that one
id pays at most once, and seven invariants over random sequences of payments, funding, sweeps and
withdrawals.

Invariant depth follows the profile: `FOUNDRY_PROFILE=quick` while iterating, `deep` before a
deployment.

## Deployment

Predicted addresses are committed before anything is broadcast, so any funded key can deploy the
same contract to a new chain in one command. The prototype is predicted by
[`io/PaymentQueue/PaymentQueue.sh`](io/PaymentQueue/PaymentQueue.sh) and lands at the same address on
every chain that has Nick's deterministic deployer:

```
0x78375585DccD757174E162dAc1781aa422eCb139
```

```bash
bash io/PaymentQueue/PaymentQueue.sh                              # predict (offline)
bash lib/crucible/script/deploy.sh <chain> <addr>                 # dry run
bash lib/crucible/script/deploy.sh -b <chain> <addr>              # broadcast
ETHERSCAN_API_KEY=… bash lib/crucible/script/verify.sh <chain> <addr>
```

Queues are clones, and a queue names its owner, so each is predicted in the repo that uses it, with
its own `io/<Queue>/<Queue>.sh` calling `clone_predict`. `deploy.sh` reads sibling repos' `io/`
directories, so a consuming repo deploys its own queue without vendoring this one. See
[crucible/docs/deployment.md](https://github.com/uniteum/crucible/blob/main/docs/deployment.md).

## Dependencies

- [ipaymentqueue](https://github.com/uniteum/ipaymentqueue) — the interface
- [proto](https://github.com/uniteum/proto) and [iproto](https://github.com/uniteum/iproto) — the
  Bitsy prototype base
- [clones](https://github.com/uniteum/clones) — EIP-1167 minimal proxies
- [erc20](https://github.com/uniteum/erc20), [ierc20](https://github.com/uniteum/ierc20) — SafeERC20
  and the interfaces
- [reentrancy](https://github.com/uniteum/reentrancy) — transient-storage reentrancy guard
- [crucible](https://github.com/uniteum/crucible) — shared Foundry config and the deployment pipeline

## License

MIT License — Copyright (c) 2026 Uniteum
