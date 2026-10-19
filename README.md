# PaymentQueue

> Idempotent ERC-20 payout queues, made by anyone for themselves. Pay each id once, keep a fee from
> each payment, hold what the funds cannot cover, and never let one refused transfer block the rest.

A queue pays out a single ERC-20 token from funds that anyone can top up. Its owner submits each
payment under an **id of its own choosing**, and that id is the idempotency key: the first `pay` for
an id fixes its recipient, amount and fee, and every later `pay` for it does nothing. An off-chain
system that loses a response, retries, or runs twice cannot pay twice, and needs no record of its own
to make that true — the guarantee is chain state.

The fit is any payout where something off-chain decides who is owed, the same instruction may arrive
more than once, and the funds can run short: batch payouts keyed by an external id, withdrawal
queues keyed by a withdrawal id, claims keyed by a claim id, or bridge exits keyed by a source-chain
message id.

## How it works

**Pay.** `pay(id, recipient, amount, feeBasisPoints)`, owner only. With nothing waiting and funds
enough to cover the whole amount, the queue transfers at once and records the id `Paid`. Otherwise
the payment joins the back of the line as `Queued` — a new payment never passes one already waiting.

**Fee.** Each payment names its own fee, in basis points of its amount. When the payment is paid the
recipient gets the amount less the fee, rounded in the recipient's favour, and the fee accrues to
`fees()`. Accrued fees sit in the queue's balance but are not funds: `funds()` is the balance less
`fees()`, and only the funds pay anyone. A payment that waits carries the fee fixed when it was
submitted; a payment the token refuses earns nothing.

**Sweep.** `processPayments(limit)` is permissionless. It pays waiting payments oldest first while
the funds cover the next one, stops at the first it cannot cover, and settles no more than `limit`,
so its gas is bounded by the caller. Simulating the call says how many it would settle, so nobody
need spend gas on a sweep that would do nothing.

**Refusal.** A transfer the token refuses — USDC refuses a blacklisted recipient, older tokens return
`false` — records that id `Failed` and moves on. A refused payment never blocks the payments behind
it, and its amount stays in the funds. A `Failed` id is spent: submitting it again does nothing.

**Status.** `statusOf(id)` is `Unknown`, `Queued`, `Paid` or `Failed`, and `queued()` counts what is
waiting. `pay` returns the id's status, so simulating it previews the outcome. `blockOf(id)` is the
block that set the status, so the transaction behind it is one single-block log query away, however
old it is.

**Funds.** Anyone can send the token to a queue. `withdrawFunds(to, amount)` takes funds back out and
`withdrawFees(to, amount)` takes accrued fees, each bounded by its own total, both owner only.
Native currency is refused rather than stranded.

### Accepted limits

One token per queue. FIFO only: no priority, no cancellation, no expiry, no partial payment. A
waiting payment the funds cannot cover holds up those behind it — honest ordering, at the cost of
head-of-line blocking. One owner, fixed.

## Architecture

PaymentQueue is a [Bitsy](https://uniteum.one/bitsy/) prototype. The deployed contract is an inert
factory: it has no owner, no token and no funds, and pays nothing. Each queue is an EIP-1167 clone of
it, made by whoever wants one:

```solidity
IPaymentQueue queue = prototype.make(address(token), 0);   // the caller owns it, for good
```

A queue's address is derived from its owner and token, so `made(owner, token, variant)` names it
before it exists, and making it again returns the same queue. Owner and token are set once, by
`zzInit`, which only the prototype can call. `variant` is a vanity-mining input; pass 0 for the
canonical address.

The token may also be given as an [`IAddressLookup`](https://github.com/uniteum/ilookup): a contract
whose `value()` is the token's address on the current chain. The queue's address is derived from the
lookup, and the queue pays in whatever the lookup resolves to, so one queue keyed by a lookup has the
same address on every chain while paying in each chain's own token. A lookup that resolves to
`address(0)`, or any address with no code, is refused with `UnmappedLookup`.

Two protections are worth knowing about, because both are easy to leave out:

- **The queue is `nonReentrant`.** Against a token with transfer hooks, a recipient can otherwise
  re-enter a sweep partway through its own payment and be paid repeatedly, draining the funds.
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

IPaymentQueue queue = prototype.make(address(token), 0);

// Fund it: any transfer of the token to the queue's address will do.
token.transfer(address(queue), 1_000e6);

// Pay once per id, whatever happened to the call before: alice gets 24.25, the queue keeps 0.75.
IPaymentQueue.Status status = queue.pay(uint256(keccak256("invoice-4718")), alice, 25e6, 300);

// Anyone can sweep what is waiting.
queue.processPayments(10);
```

## Testing

```bash
forge test
```

62 tests: the queue's behaviour against a well-behaved token, the fee's arithmetic and accounting,
refusals by revert and by `false` return, a recipient that re-enters the sweep, a gas-starved sweep
scanned across gas limits, how queues are made, directly and from a lookup, the four cases carried
over from the v1 contract this replaces, a fuzz test that one id pays at most once, and eight
invariants over random sequences of payments at random fees, funding, sweeps and withdrawals of funds
and of fees.

Invariant depth follows the profile: `FOUNDRY_PROFILE=quick` while iterating, `deep` before a
deployment.

## Deployment

Predicted addresses are committed before anything is broadcast, so any funded key can deploy the
same contract to a new chain in one command. The prototype is predicted by
[`io/PaymentQueue/PaymentQueue.sh`](io/PaymentQueue/PaymentQueue.sh) and lands at the same address on
every chain that has Nick's deterministic deployer:

```
0x1eE563EC966def14496481E1e5745022979F0868
```

Two earlier prototypes stay under `io/PaymentQueue/` so they can still be verified:
`0xd043b5804E417f146CA886D7b9eA20F0e85A1e02`, which kept no fee, and
`0x78375585DccD757174E162dAc1781aa422eCb139`, which took only a token and not a lookup.

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
- [ilookup](https://github.com/uniteum/ilookup) — the lookup interface a token may be given as
- [proto](https://github.com/uniteum/proto) and [iproto](https://github.com/uniteum/iproto) — the
  Bitsy prototype base
- [clones](https://github.com/uniteum/clones) — EIP-1167 minimal proxies
- [erc20](https://github.com/uniteum/erc20), [ierc20](https://github.com/uniteum/ierc20) — SafeERC20
  and the interfaces
- [reentrancy](https://github.com/uniteum/reentrancy) — transient-storage reentrancy guard
- [crucible](https://github.com/uniteum/crucible) — shared Foundry config and the deployment pipeline

## License

MIT License — Copyright (c) 2026 Uniteum
