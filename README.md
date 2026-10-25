# CounterGame

One shared on-chain counter starts at **0**. Calling `increment()` once adds
**100**. Calling `decrement()` once subtracts **100**. The caller whose increment
first reaches **1,000** is recorded as the winner, and both moves then revert
permanently.

## Gameplay assumptions

- “Up 1” means one call adding 100 points. There is no arbitrary amount argument.
- The counter belongs to the whole game, not to individual wallets.
- Anyone can play, including another wallet lowering the counter. “Someone else”
  is interpreted as permission for other players, not a requirement to alternate:
  the same caller can make consecutive moves in either direction.
- The counter cannot become negative. Decrementing at zero reverts.
- Only the final increment's caller wins, regardless of previous contributions.
  An address of zero in `winner()` means that there is no winner yet; it is not a
  configured recipient or deployment parameter.
- One deployment is one game. There is no reset or automatic next round. A new
  game requires a new deployment.
- Winning is recognition only. There are no entry payments, fees, rewards, token
  transfers, random selection, timeouts, or refunds. Players pay network gas.

For example, Alice increments nine times to reach 900. Bob can decrement to 800;
Carol's next increment reaches 900 without winning. Bob's next increment reaches
1,000, records Bob as the winner, and ends the game.

## Contract interface

Application: [`src/CounterGame.sol`](src/CounterGame.sol), Solidity name `CounterGame`.

| Call | Result |
| --- | --- |
| `counter()` | Shared score, from 0 to 1,000 inclusive |
| `winner()` | Winning caller, or zero before completion |
| `STEP()` | Constant 100 |
| `TARGET()` | Constant 1,000 |
| `increment()` | Adds 100; declares a winner at 1,000 |
| `decrement()` | Subtracts 100 while the game is active and above zero |

Successful moves emit
`CounterChanged(address indexed player, uint256 previousCounter, uint256 newCounter)`.
The winning increment additionally emits `WinnerDeclared(address indexed winner)`
after `CounterChanged`. A win is recorded atomically with that increment.

`CounterAtZero()` rejects a decrement at zero. `GameAlreadyWon(address winner)`
rejects either move after a win. Failed calls leave the state unchanged and emit no
events. Both moves are nonpayable. Plain native-currency transfers and unknown
function selectors also revert.

## Deployment parameters

The assignment specifies Robinhood Chain, chain ID **4663**. `CounterGame` uses
ordinary EVM storage and arithmetic and does not depend on chain-specific
addresses, clocks, block numbers, precompiles, or external contracts.

- Deploy exactly one application, `CounterGame`, from its compiled creation
  bytecode with **no constructor arguments** and **zero native value**.
- The implicit constructor is nonpayable and performs no external calls. A factory
  can deploy it on an empty chain; there is no initialization transaction.
- There is no owner or administrator, so no owner address is a deployment parameter.
  Neither the factory nor its caller receives privileges.
- Compiler: Solidity **0.8.26**. Optimization: **200 runs**. EVM target: **Paris**,
  using instructions that do not require newer EVM upgrades. Metadata bytecode hash:
  **none**, as required by the launch's bytecode comparison.
- The application has no production dependencies or linked libraries. The test
  dependency `forge-std` v1.9.7 is vendored under `lib/forge-std` with its licenses
  and exact source revision in `VENDORED.md`.

The separate launch process supplies the manifest, deploys the compiled contract,
and provides the confirmed address. This project does not broadcast transactions
or include a launch manifest.

## After launch

No settings or services need configuration. The launch operator should verify the
deployed source and compiler settings and publish the confirmed address and ABI.
An untouched instance reads `counter() == 0` and `winner() == address(0)`; because
play is permissionless, players can change it immediately after deployment.

Clients should submit moves with zero value, show the confirmed score and winner,
and handle both custom errors. Pending moves can lose a race to another player's
transaction. The chain's executed transaction order determines the winner; local
submission order does not guarantee success. Clients should handle reorganizations
and apply their normal confirmation policy before presenting a result as final.

No operator must settle or maintain the game, and no account can pause, upgrade,
reset, withdraw assets, or replace a winner. For another game, the operator needs
a separate deployment and must publish its distinct address.

## Operational limits and security

- This is a permissionless counter race. It provides no randomness, turn-taking,
  identity verification, rate limit, or guarantee of fair transaction ordering.
  A single participant can make all ten increments, and a smart contract can batch
  them in one transaction. Other participants can repeatedly lower the score and
  delay completion indefinitely. These behaviors follow the chosen game rules.
- The winning identity is `msg.sender`. A smart wallet is credited as the wallet
  contract; an intermediary that forwards moves is credited as that intermediary.
  Clients should account for this when using relayers or batching services.
- The contract makes no external calls or payouts, so moves have no callback or
  reentrancy surface. There is no asset custody feature. Native currency forced
  into the address and tokens sent directly to it cannot be recovered; neither
  affects scoring. Do not fund the game.
- Fixed 100-point steps, the zero check, and the terminal win guard keep all scores
  in the range 0..1,000. Arithmetic remains checked by Solidity.
- Automated checks are not an independent security audit. Deployment review remains
  the launch process's responsibility; Slither and Mythril were not run here.

## Build and tests

From the repository root, with Foundry and Solidity 0.8.26 available:

```sh
forge build
FOUNDRY_FUZZ_SEED=0xf92fc220ee883aa0a9dc9e14ba1c5db1796934276c3460836d8856b170bc602b forge test
forge fmt --check
```

All library source files needed for tests are included as ordinary files. No
network access, fork, RPC, environment reads in test code, FFI, filesystem
permissions, private keys, or post-deployment service is required. The shell seed
above is consumed by Foundry's runner, not read or changed by Solidity tests.

The unit tests cover shared moves, repeated participation, zero boundaries, event
contents and ordering, the exact winning move, competing moves, permanent game
completion, smart wallets, atomic batch failure, value rejection, unsolicited
balances, and independent factory deployments. Fuzz tests check arbitrary callers,
all active scores, and mixed sequences against an independent step-count model.
Stateful invariant tests check that accepted moves are fully accounted for, the
score stays bounded in 100-point steps, and the winner is set exactly at the target
and never changes. Default fuzzing uses 512 runs; each invariant uses 256 runs of
up to 64 moves. Tests create their own fresh deployments and do not depend on order.
