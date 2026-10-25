# CounterGame test coverage

Run from the repository root with the existing vendored dependencies:

```sh
forge build --offline
FOUNDRY_FUZZ_SEED=0xf92fc220ee883aa0a9dc9e14ba1c5db1796934276c3460836d8856b170bc602b forge test --offline
```

| Suite | Coverage |
| --- | --- |
| `CounterGame.t.sol` | Existing deployment, shared score, 100-point moves, exact errors and events, winner identity, completed-game rejection, smart-wallet calls, and arbitrary move sequences. |
| `CounterGame.adversarial.t.sol` | Cancelling moves at active scores; exact and overlong batches from partial progress; whole-transaction rollback; caught failures followed by valid moves; wallet aborts; nonpayable winning attempts and successful retries. Six fuzz properties run 1,000 cases each. |
| `CounterGame.invariant.t.sol` | Three actors, five randomized handler actions, six invariants, and a deterministic handler boundary test. Inline settings run 256 sequences of 128 actions with unexpected handler reverts treated as failures. |

The invariant handler tracks accepted increments and decrements independently in
units of moves. It checks both custom error payloads, unchanged state on rejection,
and exact event counts, actors, values, and ordering after each move. The permanent
winner must agree with the model and have exactly one announcement. Round trips
exercise continued play without resetting the game. After every random sequence,
`afterInvariant()` finishes any active game and checks that both moves reject all
three actors after a win.

The contract has no payment or payout interface. The handler mixes rejected ETH
transfers with unsolicited balances modeled using `vm.deal`, checking that gameplay
neither consumes that balance nor accepts additional payments. This changes only
ETH balances; scores and winners are reached through the public game functions.

`CounterBatchWallet` executes a batch in one external call so it is one transaction
under Forge 1.8. Tests distinguish bubbling a failure (all batch progress rolls
back) from catching it (earlier successful moves remain). Event assertions cover
successful transactions and directly rejected moves; they do not infer transaction
receipt logs from cheatcode recordings of a reverted outer wallet call.
