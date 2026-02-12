# Apex Report - WNS / Scan #1

## Table of contents

- [High](#high)
  - [WNS-1 — ZAMM orderbook: taker can bypass paying maker by consuming transient balance in _payOut (maker receives nothing)](#finding-wns-1)
  - [WNS-8 — swapVZ exactOut refunds ERC6909 inputs incorrectly, trapping user idIn balances in router](#finding-wns-8)
  - [WNS-7 — Permissionless zRouter.execute() allows any attacker to spend router-held funds via owner trust allowlist](#finding-wns-7)
  - [WNS-4 — zRouter.addLiquidity sources ERC20 from router balance (ZAMM pulls from msg.sender=zRouter) while minting LP to attacker-chosen recipient](#finding-wns-4)
- [Medium](#medium)
  - [WNS-14 — Dapp XSS: unescaped on-chain name injected into innerHTML/href](#finding-wns-14)
  - [WNS-13 — Commit owner set to router breaks commit-reveal and enables mempool name theft](#finding-wns-13)
  - [WNS-10 — NameNFT reveal/renew refunds pay msg.sender; with official zRouter-based registration this misdirects user refunds to zRouter](#finding-wns-10)
- [Low](#low)
  - [WNS-12 — Unrestricted zRouter.sweep() lets any attacker steal all ETH/ERC20/ERC6909 held by the router](#finding-wns-12)
  - [WNS-9 — zRouter.swapCurve exactOut refunds all router ETH+WETH to caller (cross-user drain)](#finding-wns-9)
  - [WNS-11 — zRouter snwap/snwapMulti drain router-held ERC20 when amountIn==0 by transferring balance to attacker-chosen executor](#finding-wns-11)
  - [WNS-2 — zRouter.swapV2 exactIn ETH swaps can steal router-held ETH with msg.value=0](#finding-wns-2)
  - [WNS-5 — swapCurve: attacker-controlled pool drains router tokens in the same transaction via lazy approve + external call](#finding-wns-5)
  - [WNS-3 — zRouter.swapV3 exactOut (ETH-in) can be executed with msg.value=0 via callback wrapETH, spending router-held ETH](#finding-wns-3)
  - [WNS-6 — zRouter.swapCurve exactOut refunds router-held ERC20 input balance to caller (cross-user drain)](#finding-wns-6)

<a id="high"></a>
## High

<a id="finding-wns-1"></a>
### WNS-1 — ZAMM orderbook: taker can bypass paying maker by consuming transient balance in _payOut (maker receives nothing)

#### ZAMM orderbook: taker can bypass paying maker by consuming transient balance in _payOut (maker receives nothing)

##### Executive Summary
ZAMM’s on-chain orderbook (`makeOrder` / `fillOrder`) is intended to atomically exchange a maker asset (`tokenIn`) for a taker payment (`tokenOut`). However, the internal payment helper `_payOut()` treats a caller’s transient balance as a valid “payment” and returns early without transferring any value to the maker. As a result, a taker can fill orders such that the maker’s asset is delivered to the taker (`_payIn`), while the maker receives no payment. This breaks the fundamental safety invariant of the orderbook and enables direct loss for makers who have approved/escrowed their sell-asset.

The exploit is permissionless and requires no admin privileges. The taker only needs to pre-credit a transient balance for `tokenOut` (e.g., via `deposit()` in the same transaction) and then call `fillOrder()`.

##### Details
The vulnerable sequence is:

- `fillOrder()` updates order accounting, then performs the taker-payment leg via `_payOut(tokenOut, idOut, sliceOut, maker)`, then delivers the maker asset via `_payIn(tokenIn, idIn, sliceIn, maker)`.

```solidity
// ZAMM.fillOrder
_payOut(tokenOut, idOut, sliceOut, maker);
_payIn(tokenIn, idIn, sliceIn, maker);
```

`_payOut()` is intended to transfer `tokenOut` from the taker (`msg.sender`) to the maker (`to`). Instead, if the taker has enough transient balance, `_payOut()` consumes transient balance and returns without sending anything to the maker:

```solidity
function _payOut(address token, uint256 id, uint96 amt, address to) internal {
    if (_useTransientBalance(token, id, amt)) {
        require(msg.value == 0, InvalidMsgVal());
        return;
    }
    // ... otherwise transfer/burn+mint tokenOut to `to`
}
```

Because transient consumption does not perform an ERC20 transfer / ETH transfer / ERC6909 transfer to `maker`, the maker receives nothing but the taker still receives the maker leg via `_payIn()`.

###### Concrete exploit path
1. Maker creates an order selling some valuable `tokenIn` for `tokenOut` and (if needed) grants allowance/escrows ETH so `_payIn` can succeed.
2. Attacker (taker) pre-credits transient balance for `tokenOut` by calling `deposit(tokenOut, idOut, sliceOut)` (or otherwise accumulating transient for the same `(tokenOut, idOut)` under their caller address).
3. Attacker calls `fillOrder(...)` for that order.
4. `_payOut()` takes the transient path and returns early, so maker receives no `tokenOut`.
5. `_payIn()` executes and transfers the maker leg to the attacker.

This is an on-chain correctness failure: makers can lose assets without receiving the payment asset.

##### Impact Cascade
- Maker asset theft: taker receives `tokenIn` while maker receives no `tokenOut`.
- Protocol integrity failure: orderbook cannot be safely used (atomic exchange property is broken).
- Secondary losses: makers may list orders relying on escrow/allowances and get drained without compensation.

##### Assumptions and Uncertainties
1. Makers approve/escrow their `tokenIn` such that `_payIn()` can succeed (e.g., ERC20 allowance to ZAMM, or ETH escrow via `makeOrder` when `tokenIn == address(0)`).
2. Taker can pre-credit transient balance for `tokenOut` (e.g., `deposit()`), which is feasible because `deposit()` is not `lock`-gated.
3. This finding is based on the verified mainnet source for `ZAMM` at `0x000000000000040470635EB91b7CE4D132D616eD`.

##### Why did tests miss this issue? Why has it not been surfaced?
- The repository’s POCs focus heavily on `zRouter` custody/refund drains and NameNFT flows; there are no local tests covering ZAMM’s orderbook invariants.
- In practice, users may not use ZAMM’s embedded orderbook heavily, delaying detection.

##### Recommendation
- In `_payOut()`, when transient balance is used, the contract must still deliver the payment to the maker.
  - Option A: if transient represents assets already held by the contract “on behalf of” the caller, redirect the payout by transferring from contract to `to` (ETH/ERC20/ERC6909) and decrementing transient accordingly.
  - Option B: remove transient-balance support from orderbook payment paths entirely (always require explicit taker transfer for `tokenOut`).

##### References
1. `/tmp/d8b27007-8735-466f-8a64-9edb29226b45/zamm-src/src/ZAMM.sol:772`
2. `/tmp/d8b27007-8735-466f-8a64-9edb29226b45/zamm-src/src/ZAMM.sol:858`
3. `/tmp/d8b27007-8735-466f-8a64-9edb29226b45/zamm-src/src/ZAMM.sol:903`

> **Response:** Acknowledged as an edge case, but the characterization as fund theft is incorrect. The transient path in `_payOut` is **by design** for the controlled redemption / token upgrade use case, as documented at https://docs.zamm.eth.limo/:
>
> *"Users may create an order that pays out a new token in exchange for users programmatically burning it by making a transient deposit that gets spent on their 'fill'."*
>
> The intended pattern: a token upgrader creates an order ("Send me OldToken, receive NewToken"), users deposit OldToken into ZAMM (transient credit), then fill the order — OldToken stays in ZAMM (effectively burned), user receives NewToken. The maker intentionally does not need to receive OldToken.
>
> **This is not a profitable exploit.** The taker calls `deposit(tokenOut, idOut, sliceOut)` — real tokens transfer to ZAMM. `_payOut` consumes transient credit and returns early — maker gets nothing. `_payIn` sends tokenIn to taker. But the taker's deposited tokens are **bricked in ZAMM** — the transient balance was consumed, so `recoverTransientBalance` cannot retrieve them. The taker's net cost is identical to the normal fill path. At worst this is a grief vector (taker loses their tokens, maker doesn't get paid), but the taker has no economic incentive since they lose equivalent value.

<a id="finding-wns-8"></a>
### WNS-8 — swapVZ exactOut refunds ERC6909 inputs incorrectly, trapping user idIn balances in router

#### swapVZ exactOut refunds ERC6909 inputs incorrectly, trapping user idIn balances in router

##### Executive Summary
`zRouter.swapVZ` supports ERC6909 inputs via `idIn != 0` and uses `IERC6909(tokenIn).transferFrom` to pre-pull up to `amountLimit` of the ERC6909 id into the router for `exactOut` swaps. However, when `exactOut && to != address(this)` (the branch that is supposed to refund unused input), the refund logic is ERC20-only: it reads `balanceOf(tokenIn)` and calls `safeTransfer(tokenIn, msg.sender, refund)`. This ignores `idIn` entirely.

If the zAMM exact-out swap consumes less than `amountLimit`, the unused ERC6909 balance (tokenIn, idIn) remains in the router and is never returned to the user. Those trapped id-tokens are then stealable by third parties via the router’s ERC6909 sweep mechanism.

##### Details

###### ERC6909 input is pulled, but refund only considers ERC20 balance
`swapVZ` pulls ERC6909 inputs when `idIn != 0`:

```solidity
if (!ethIn) {
    if (idIn == 0) {
        safeTransferFrom(tokenIn, msg.sender, address(this), amountLimit);
    } else {
        IERC6909(tokenIn).transferFrom(msg.sender, address(this), idIn, amountLimit);
    }
}
```

But in the refund branch (`exactOut && to != address(this)`), it computes `refund` using `balanceOf(tokenIn)` and sends it via ERC20 `safeTransfer`:

```solidity
if (exactOut && to != address(this)) {
    uint256 refund = ethIn ? address(this).balance : balanceOf(tokenIn);
    if (refund != 0) {
        if (ethIn) _safeTransferETH(msg.sender, refund);
        else safeTransfer(tokenIn, msg.sender, refund);
    }
}
```

For ERC6909 inputs, `balanceOf(tokenIn)` is unrelated to the ERC6909 id balance. Unused `(tokenIn, idIn)` remains in the router.

###### Exploit path (unprivileged attacker)
1. Victim executes an exact-out zAMM swap through `swapVZ` with an ERC6909 input (`idIn != 0`) and `amountLimit` including a slippage buffer.
2. The zAMM swap consumes less than `amountLimit`, leaving unused ERC6909 id balance in the router.
3. The victim receives no refund for the unused ERC6909 id balance.
4. A third party calls the router’s ERC6909 sweep path to transfer the trapped id tokens to themselves.

##### Impact Cascade
- Direct user loss: unused ERC6909 input intended to be refunded is stranded in router custody.
- Theft: trapped ERC6909 id balances can be extracted by third parties.
- Integration hazard: callers who rely on `amountLimit` semantics for exact-out swaps are exposed.

##### Assumptions and Uncertainties
1. The zAMM exact-out swap can consume less than `amountLimit` for ERC6909 inputs (normal exact-out behavior).
2. The router’s ERC6909 sweep mechanism is callable without strict per-user accounting (consistent with current router design).

##### Why did tests miss this issue? Why has it not been surfaced?
- This repo’s tests target `NameNFT` and do not cover zRouter’s ERC6909 edge cases.
- ERC6909 usage is less common than ERC20, so this path is easy to miss without targeted review.

##### Recommendation
- Implement ERC6909-aware refunds in `swapVZ`:
  - Track the actual `amountIn` consumed, and refund `amountLimit - amountIn` of `(tokenIn, idIn)` to the caller.
  - Use `IERC6909(tokenIn).transfer(msg.sender, idIn, refundAmount)` for `idIn != 0`.
- Add explicit invariants/tests around ERC6909 exact-out refund behavior in the router project.

##### References
1. https://etherscan.io/address/0x0000000000001C3a3Aa8FDfca4f5c0c94583aC46#code

> **Response:** Acknowledged. Valid finding — patched.
>
> The refund block now handles all three token types (ETH, ERC20, ERC6909), mirroring the ERC6909 handling already present in `sweep()`:
>
> ```diff
>          if (exactOut && to != address(this)) {
> -            uint256 refund = ethIn ? address(this).balance : balanceOf(tokenIn);
> -            if (refund != 0) {
> -                if (ethIn) _safeTransferETH(msg.sender, refund);
> -                else safeTransfer(tokenIn, msg.sender, refund);
> +            uint256 refund;
> +            if (ethIn) {
> +                refund = address(this).balance;
> +                if (refund != 0) _safeTransferETH(msg.sender, refund);
> +            } else if (idIn == 0) {
> +                refund = balanceOf(tokenIn);
> +                if (refund != 0) safeTransfer(tokenIn, msg.sender, refund);
> +            } else {
> +                refund = IERC6909(tokenIn).balanceOf(address(this), idIn);
> +                if (refund != 0) IERC6909(tokenIn).transfer(msg.sender, idIn, refund);
>              }
>          } else {
> ```
>
> Note: the assembly `balanceOf` helper (Solady-style) returns 0 on failure rather than reverting, so for ERC6909 tokens the refund was silently skipped. The existing mitigation for users on the current deployment is via `multicall` with `to = address(this)` followed by `sweep()`.

<a id="finding-wns-7"></a>
### WNS-7 — Permissionless zRouter.execute() allows any attacker to spend router-held funds via owner trust allowlist

#### Permissionless zRouter.execute() allows any attacker to spend router-held funds via owner trust allowlist

##### Executive Summary
The on-chain `zRouter` contract (used by the official `.wei` dapp for swap-to-register flows) exposes an `execute(address target, uint256 value, bytes data)` function that is callable by anyone. The only gate is that `target` must be marked trusted by the router owner via `trust(target, true)`.

Once the allowlist is non-empty (a realistic operational state for a “generic executor” router), any remote attacker can call `execute()` to make `zRouter` perform arbitrary external calls against those trusted targets, spending `zRouter`’s ETH balance and any ERC20/ERC6909 balances/approvals that the trusted target can access. This creates a broad asset-drain surface that does not require attacker privileges.

##### Details
The router owner can mark targets trusted:

```solidity
// zRouter.sol
mapping(address target => bool) _isTrustedForCall;

function trust(address target, bool ok) public payable onlyOwner {
    _isTrustedForCall[target] = ok;
}
```

But `execute()` is permissionless; it does not check `msg.sender` beyond the allowlist:

```solidity
// zRouter.sol
function execute(address target, uint256 value, bytes calldata data)
    public
    payable
    returns (bytes memory result)
{
    require(_isTrustedForCall[target], Unauthorized());
    ...
    if iszero(call(gas(), target, value, ...)) { revert(...) }
    ...
}
```

Notably:
- `value` is attacker-controlled.
- No constraint ties `value` to `msg.value`, so the call can spend `zRouter`’s existing ETH balance.
- `data` is attacker-controlled, so any function on the trusted target can be invoked.

##### Exploit Sketch
1. Router operator (owner) marks one or more targets trusted (expected for production use).
2. Attacker calls `zRouter.execute(trustedTarget, value, data)`.
3. The trusted target call spends router-held ETH and/or uses router-held ERC20 approvals/balances (depending on what the target can do).

The attacker does not need to be the owner and does not need any prior approvals from victims.

##### Impact Cascade
- Direct financial loss: router ETH balance can be spent/sent out by any attacker once a trusted target exists.
- Token theft amplification: if the router ever holds ERC20/ERC6909 balances or allowances (common in routers with refund/aggregation flows), trusted targets can be used to extract them.
- Operational compromise: any “trusted executor” feature becomes a public API for attackers.

##### Assumptions and Uncertainties
1. `_isTrustedForCall` will be set non-empty in production operations (otherwise the function is inert).
2. The router holds ETH/tokens at some times (plausible due to refunds, slippage buffers, and multi-step flows).
3. At least one trusted target exposes call paths that can move value out of `zRouter` (typical for routers/executors).

##### Why did tests miss this issue? Why has it not been surfaced?
This is not covered by the `wei-names` Solidity unit tests because `zRouter` is an external deployed dependency, not part of the `wei-names/src` contract.

##### Recommendation
- Restrict `execute()` to `onlyOwner` (or a tightly scoped executor role), or
- Add a caller allowlist separate from the target allowlist, and
- Enforce `require(msg.value == value)` (or otherwise prevent spending router-held ETH).

##### References
1. https://etherscan.io/address/0x0000000000001c3a3aa8fdfca4f5c0c94583ac46#code

> **Response:** Acknowledged as informational / by-design. The finding does not introduce attack surface beyond what already exists:
>
> 1. **`execute()` is intentionally permissionless.** It is part of the router's multicall-composable design. Restricting it to `onlyOwner` would break composability for normal users routing through multicall.
> 2. **`sweep()` already subsumes the fund-theft angle.** `sweep()` is equally permissionless and lets anyone drain any ETH, ERC20, or ERC6909 sitting in the router. The `value != msg.value` concern does not create additional attack surface — `sweep()` does this more directly.
> 3. **The router does not hold funds between transactions.** It is designed as a transient fund holder. Funds flow through it within a single atomic multicall. Any balance sitting in the router between transactions is by-design claimable by anyone via `sweep()` as a safety valve.
> 4. **The trust list is owner-controlled.** The `trust()` function is `onlyOwner`. The owner is responsible for only adding safe, vetted targets to the allowlist.
>
> Operational note: care is taken to avoid adding contracts to `_isTrustedForCall` that are also targets of the router's persistent token approvals (e.g., Curve pools approved via lazy `safeApprove` in `swapCurve`), as that combination could compound risk.

<a id="finding-wns-4"></a>
### WNS-4 — zRouter.addLiquidity sources ERC20 from router balance (ZAMM pulls from msg.sender=zRouter) while minting LP to attacker-chosen recipient

#### zRouter.addLiquidity sources ERC20 from router balance (ZAMM pulls from msg.sender=zRouter) while minting LP to attacker-chosen recipient

##### Executive Summary
`zRouter.addLiquidity()` is a public function intended to be used after deposits/swaps for ZAMM liquidity management. It forwards directly into `ZAMM.addLiquidity(...)`.

Because the ZAMM call is made by `zRouter`, ZAMM treats `msg.sender` as the liquidity provider and pulls the token amounts from `zRouter` via `transferFrom(msg.sender, ...)` when no transient credit exists. However, ZAMM mints the LP position (an ERC6909 token) to the user-supplied `to` parameter.

This lets a remote attacker steal router-held ERC20 balances: the attacker supplies only the ETH leg (via `msg.value`), chooses an ERC20 `token1` that `zRouter` currently holds (and has approved for ZAMM pulls), sets `amount1Desired` to drain it, and sets `to=attacker`. The attacker receives LP tokens backed by the stolen ERC20 and can immediately call `ZAMM.removeLiquidity` to withdraw the underlying assets.

##### Details
Affected components: deployed `zRouter` at `0x0000000000001C3a3Aa8FDfca4f5c0c94583aC46` and `ZAMM` at `0x000000000000040470635EB91b7CE4D132D616eD`.

`zRouter.addLiquidity` forwards to ZAMM without any access control:
```solidity
function addLiquidity(
    PoolKey calldata poolKey,
    uint256 amount0Desired,
    uint256 amount1Desired,
    uint256 amount0Min,
    uint256 amount1Min,
    address to,
    uint256 deadline
) public payable returns (uint256 amount0, uint256 amount1, uint256 liquidity) {
    bool ethIn = (poolKey.token0 == address(0));
    (amount0, amount1, liquidity) = IZAMM(ZAMM).addLiquidity{value: ethIn ? amount0Desired : 0}(
        poolKey, amount0Desired, amount1Desired, amount0Min, amount1Min, to, deadline
    );
}
```

In ZAMM, if no transient credit exists, it pulls tokens from `msg.sender` (here: `zRouter`):
```solidity
// token0
_safeTransferFrom(poolKey.token0, msg.sender, address(this), poolKey.id0, amount0);
// token1
_safeTransferFrom(poolKey.token1, msg.sender, address(this), poolKey.id1, amount1);
```

And the LP is minted to the user-provided `to`:
```solidity
_initMint(to, poolId, liquidity);
```

Exploit path:
1. Preconditions: `zRouter` holds a balance of ERC20 token `T` and has granted ZAMM sufficient allowance to pull `T` from `zRouter` (operationally required for ZAMM-based swaps).
2. Attacker calls `zRouter.addLiquidity(...)` with `poolKey.token0 = address(0)` and `poolKey.token1 = T`, sets `amount0Desired` to a small ETH amount (and supplies that ETH via `msg.value`), and sets `amount1Desired` high enough to drain `zRouter`’s `T` balance. Set `to = attacker`.
3. ZAMM pulls `T` from `zRouter` and mints LP to `attacker`.
4. Attacker calls `ZAMM.removeLiquidity(poolKey, liquidity, 0, 0, attacker, deadline)` to withdraw the underlying assets.

Root cause: `zRouter.addLiquidity` exposes a liquidity-management primitive that sources from router balances rather than caller balances, while allowing the caller to select the LP recipient.

##### Impact Cascade
- Direct token theft: drains router-held ERC20 balances into attacker-owned LP and then into attacker wallet.
- Cross-user impact: any router-held token balances (including stranded balances from other flows) become stealable.

##### Assumptions and Uncertainties
1. `zRouter` holds the target ERC20 at the time of attack.
2. ZAMM has allowance/operator rights to pull that ERC20 from `zRouter` (common in ZAMM-integrated routing setups).

##### Why did tests miss this issue? Why has it not been surfaced?
The repo does not contain adversarial tests for the deployed router + ZAMM composition where a public helper unintentionally sources funds from the router.

##### Recommendation
- Restrict `zRouter.addLiquidity` so that it only uses explicit per-caller credits (transient accounting) and/or requires the caller to provide funds directly.
- At minimum, require `msg.sender == to` and require the router not to source tokens from its own balances.

##### References
1. https://etherscan.io/address/0x0000000000001C3a3Aa8FDfca4f5c0c94583aC46#code
2. https://etherscan.io/address/0x000000000000040470635EB91b7CE4D132D616eD#code

> **Response:** Acknowledged as informational / same class as WNS-7. This is another restatement of the "router doesn't custody funds" trust assumption:
>
> 1. **The precondition does not hold under normal operation.** The router does not hold token balances between transactions. Funds exist in the router only transiently within a single atomic multicall.
> 2. **`sweep()` already subsumes this.** If the router holds a token balance, anyone can call `sweep(token, 0, 0, attacker)` to take it directly — no need for the `addLiquidity` → `removeLiquidity` roundtrip. The `addLiquidity` path does not create additional attack surface.
> 3. **`addLiquidity` is intentionally permissionless.** It is part of the router's multicall-composable design, allowing users to add liquidity as a step within a multicall sequence (e.g., swap → add liquidity in one transaction).

<a id="medium"></a>
## Medium

<a id="finding-wns-14"></a>
### WNS-14 — Dapp XSS: unescaped on-chain name injected into innerHTML/href

#### Dapp XSS: unescaped on-chain name injected into innerHTML/href

##### Executive Summary
The `weiNS.html` dapp renders the on-chain name string (`name` / `currentTokenName`) into HTML using `innerHTML` and template literals without applying `escapeHtml`. Because the on-chain contract’s label validation only rejects spaces/control characters/dots, an attacker can register a `.wei` label containing HTML-special characters such as `"`, `'`, `<`, or `>`.

When a victim user views that name in the dapp (e.g., by searching it or via a shared `#hash` link), the dapp interpolates the malicious name into HTML attributes and markup, enabling script execution in the dapp origin. This can be escalated into wallet phishing/drain by rewriting UI elements, spoofing transaction prompts, or swapping destination addresses.

##### Details
Code locations (unescaped interpolation into HTML):

```javascript
// showManage(tokenId, name)
const gatewayUrl = `https://${name}.${WEI_GATEWAY}`;
infoHtml += `<div><span>Website:</span><a href="${gatewayUrl}" target="_blank" rel="noopener" style="color:inherit;">${gatewayUrl}</a></div>`;
$('manageInfo').innerHTML = infoHtml;
```

```javascript
// showManageForm(...)
html = `
  <div style="font-size:11px;opacity:0.5;margin-bottom:8px;">Transfers to ${currentTokenName}.wei will go to this address</div>
  ...
  ${WEI_GATEWAY ? `<a href="https://${currentTokenName}.${WEI_GATEWAY}" ...>${currentTokenName}.${WEI_GATEWAY}</a>` : ''}
`;
form.innerHTML = html;
```

The dapp can accept labels that ENSIP-15 normalization rejects because it falls back to contract-compatible validation:

```javascript
function normalizeLabel(label) {
  try {
    const normalized = ens_normalize(s);
    ...
    return normalized;
  } catch (e) {
    return normalizeLabelContract(s);
  }
}

function normalizeLabelContract(s) {
  // Reject control chars, space, dot, DEL (matches contract)
  if (/[\u0000-\u0020\u007f.]/.test(s)) return null;
  ...
  return lowered;
}
```

Exploit sketch:
1. Attacker registers a label containing a payload such as `"><img src=x onerror=...>`.
2. Victim visits the dapp page for that name.
3. The dapp calls `showManage(tokenId, name)` and/or `showManageForm(...)`, assigning `innerHTML` that contains the unescaped name.
4. Payload executes in the dapp origin, enabling transaction phishing.

##### Impact Cascade
- Account compromise: attacker-controlled JS can manipulate transaction recipients/amounts shown to the user.
- Wallet phishing: attacker can present fake UI states or prompt malicious approvals.
- Trust/identity corruption: reverse-name display becomes a delivery mechanism for active attacks.

##### Assumptions and Uncertainties
1. Users access the official dapp origin and interact with it while connected to a wallet.
2. The dapp is served as-is (no CSP that blocks inline event handlers / injected script execution).

##### Why did tests miss this issue? Why has it not been surfaced?
- The Foundry test suite targets the Solidity contract and does not cover the dapp.
- The bug triggers only for labels containing HTML-special characters; these are uncommon in normal use.

##### Recommendation
- Escape all on-chain strings before inserting into `innerHTML`, including attribute values.
- Prefer DOM APIs (`textContent`, `setAttribute`) instead of HTML templating for untrusted content.
- Add a strict Content Security Policy (CSP) to reduce XSS blast radius.

##### References
1. [wei-names/dapp/weiNS.html:2215](https://github.com/z0r0z/wei-names/blob/49abd2bb380112a8943619228c5a727bff276c40/dapp/weiNS.html#L2215)
2. [wei-names/dapp/weiNS.html:2249](https://github.com/z0r0z/wei-names/blob/49abd2bb380112a8943619228c5a727bff276c40/dapp/weiNS.html#L2249)
3. [wei-names/dapp/weiNS.html:2293](https://github.com/z0r0z/wei-names/blob/49abd2bb380112a8943619228c5a727bff276c40/dapp/weiNS.html#L2293)
4. [wei-names/dapp/weiNS.html:1287](https://github.com/z0r0z/wei-names/blob/49abd2bb380112a8943619228c5a727bff276c40/dapp/weiNS.html#L1287)

> **Response:** Acknowledged. Valid finding — patched.
>
> The dapp already has an `escapeHtml()` utility and uses it for text records and CIDs — it was simply missing on the name interpolation points. The auditor is correct that `ens_normalize` (ENSIP-15) does not fully protect because the `catch` block falls back to `normalizeLabelContract()` which allows `<>"'` through.
>
> Applied `escapeHtml()` to all 5 unescaped name interpolation points in `showManage()` and `showManageForm()`:
> - `showManage`: gateway URL (name in href and text)
> - `showManageForm('setAddr')`: `currentTokenName` in description
> - `showManageForm('setContent')`: `currentTokenName` in description and gateway link
> - `showManageForm('subdomain')`: `currentTokenName` in subdomain preview

<a id="finding-wns-13"></a>
### WNS-13 — Commit owner set to router breaks commit-reveal and enables mempool name theft

#### Commit owner set to router breaks commit-reveal and enables mempool name theft

##### Executive Summary
The official `weiNS.html` dapp generates commitments with `owner = ZROUTER` (a router contract), not the user’s wallet address. This changes the commit-reveal “owner binding” from the registrant to a shared third-party contract. Since `NameNFT.reveal()` recomputes the commitment using `msg.sender` and mints to `msg.sender`, the router becomes the only address that can successfully reveal those commitments. As a result, the reveal step becomes MEV-front-runnable: a searcher can copy the victim’s reveal calldata (label + secret) from the mempool and submit their own router reveal first (sending the same ETH fee), setting the recipient to themselves. The first reveal deletes the commitment and transfers the NFT, and the victim’s transaction then fails, permanently losing the intended name.

##### Details

###### 1) `NameNFT.reveal` binds commitments to `msg.sender` and mints to `msg.sender`
In `NameNFT.reveal()`, the contract derives the commitment hash with `msg.sender` and then mints to `msg.sender`:

```solidity
bytes32 commitment = keccak256(abi.encode(normalized, msg.sender, secret));
uint256 committedAt = commitments[commitment];
...
delete commitments[commitment];
_register(string(normalized), 0, msg.sender);
```

This design means that whoever is encoded as `owner` inside the commitment must also be the eventual `msg.sender` of `reveal()`.

###### 2) The dapp commits with `owner = ZROUTER`, not the user
In `weiNS.html`, the commitment is computed as:

```javascript
const commitment = await rc.makeCommitment(name, ZROUTER, secret);
const tx = await wcTransaction(contract.commit(commitment), 'Approve commitment');
```

Then, reveal is performed through the router, passing an explicit `to` recipient:

```javascript
tx = await wcTransaction(router.multicall([
  rIface.encodeFunctionData('revealName', [pending.name, pending.secret, connectedAddress])
], { value: total }), 'Approve registration');
```

Because the commitment was made for `owner = ZROUTER`, the router is now the address that must call `NameNFT.reveal()` successfully.

###### 3) Exploit: front-run the reveal via the router and set yourself as recipient
Preconditions are realistic:
- Victim uses the official dapp flow (commit owner is the router).
- Victim submits the reveal tx publicly (not via a private relay), so calldata is visible in the mempool.

Attack steps:
1. Victim commits using `makeCommitment(label, ZROUTER, secret)` and waits ≥ 60 seconds.
2. Victim submits the router reveal transaction (router multicall to `revealName(label, secret, connectedAddress)`) with `value = fee + premium`.
3. Searcher copies `label` and `secret` from the pending transaction and submits their own router call first:
   - `revealName(label, secret, attackerAddress)`
   - `value = fee + premium`
4. The attacker’s reveal executes first, consuming the stored commitment (`delete commitments[commitment]`) and transferring the minted NFT to the attacker.
5. The victim’s reveal then reverts with `CommitmentNotFound()` because the commitment has been deleted.

Root cause: the commitment is not bound to the intended registrant (the user); it is bound to a shared router address.

##### Impact Cascade
- Name theft: an unprivileged searcher can capture any name being revealed through the router flow.
- Censorship/denial: victims reliably lose the name if they reveal via public mempool.
- Ecosystem harm: users may believe commit-reveal prevents front-running, but this integration negates that guarantee.

##### Assumptions and Uncertainties
1. Victim uses the router-based commitment flow (as coded in `weiNS.html`). If a user commits with `owner = userAddress` and calls `NameNFT.reveal()` directly, this specific exploit path does not apply.
2. The attacker can observe the victim’s reveal calldata in the public mempool. If the victim uses private transaction submission, the attack is mitigated.
3. The router call used by the dapp is callable by any EOA (consistent with the dapp invoking it directly).

##### Why did tests miss this issue? Why has it not been surfaced?
- The Solidity tests exercise `NameNFT.reveal()` directly from the intended owner address and do not model the router-based commitment flow used by the dapp.
- In production, users who reveal via private relays (or rarely) may not notice; public-mempool reveals are the vulnerable surface.

##### Recommendation
Primary fix (contract-level): add a relayer-safe reveal API that binds the commitment to a specified owner but does not require `msg.sender` to be that owner, e.g.:

```solidity
function revealTo(string calldata label, address owner, bytes32 secret) external payable returns (uint256 tokenId) {
    bytes memory normalized = _validateAndNormalize(bytes(label));
    bytes32 commitment = keccak256(abi.encode(normalized, owner, secret));
    ...
    _register(string(normalized), 0, owner);
}
```

Dapp-side mitigation (insufficient alone if a router must reveal): do not create commitments with `owner = ZROUTER`. Commitments should be bound to the end owner, and the reveal call should be performed either by that owner or by a relayer-safe `revealTo` function.

##### References
1. https://github.com/z0r0z/wei-names/blob/49abd2bb380112a8943619228c5a727bff276c40/src/NameNFT.sol#L251
2. https://github.com/z0r0z/wei-names/blob/49abd2bb380112a8943619228c5a727bff276c40/src/NameNFT.sol#L266
3. https://github.com/z0r0z/wei-names/blob/49abd2bb380112a8943619228c5a727bff276c40/src/NameNFT.sol#L273
4. https://github.com/z0r0z/wei-names/blob/49abd2bb380112a8943619228c5a727bff276c40/dapp/weiNS.html#L642
5. https://github.com/z0r0z/wei-names/blob/49abd2bb380112a8943619228c5a727bff276c40/dapp/weiNS.html#L1567
6. https://github.com/z0r0z/wei-names/blob/49abd2bb380112a8943619228c5a727bff276c40/dapp/weiNS.html#L1691

> **Response:** Acknowledged. Valid finding — patched.
>
> **NameNFT itself is not vulnerable** — direct calls to `NameNFT.reveal()` bind the commitment to the caller's own address, which is correct. The issue only exists in the router path where the commitment is bound to the shared router address to enable atomic swap-to-reveal from USDC/DAI. NameNFT does not need redeployment. The fix is applied entirely in zRouter and the dapp.
>
> **zRouter patch:** `revealName` now derives the actual secret from `keccak256(abi.encode(innerSecret, to))`, binding the commitment to the intended recipient. An attacker who changes `to` produces a different derived secret, which doesn't match any commitment.
>
> ```diff
> -    function revealName(string calldata label, bytes32 secret, address to)
> +    function revealName(string calldata label, bytes32 innerSecret, address to)
>          public payable returns (uint256 tokenId)
>      {
> +        bytes32 secret = keccak256(abi.encode(innerSecret, to));
>          uint256 val = address(this).balance;
>          ...
>      }
> ```
>
> **Dapp patch:** commit phase now generates an `innerSecret`, derives the real secret with the user's address baked in, and saves `innerSecret` for the reveal call.
>
> ```diff
> -    const secret = ethers.hexlify(ethers.randomBytes(32));
> +    const innerSecret = ethers.hexlify(ethers.randomBytes(32));
>      const userAddr = await signer.getAddress();
> +    const secret = ethers.keccak256(
> +        ethers.AbiCoder.defaultAbiCoder().encode(['bytes32', 'address'], [innerSecret, userAddr])
> +    );
>      const commitment = await rc.makeCommitment(name, ZROUTER, secret);
> ```

<a id="finding-wns-10"></a>
### WNS-10 — NameNFT reveal/renew refunds pay msg.sender; with official zRouter-based registration this misdirects user refunds to zRouter

#### NameNFT reveal/renew refunds pay msg.sender; with official zRouter-based registration this misdirects user refunds to zRouter

##### Executive Summary
`NameNFT.reveal()` refunds any overpayment to `msg.sender` (the caller). The official dapp’s registration flow intentionally binds commitments to a fixed router address (`ZROUTER`) and then executes the reveal via the router (so that `msg.sender` inside `reveal()` is the router). As a result, any overpayment/refund during router-based registrations is paid to the router contract, not to the end user who funded the registration. This creates a direct, repeatable user-funds loss mechanism whenever the amount sent exceeds the `fee + premium` computed at execution time (e.g., due to time-varying premium, RPC quote drift, or user overpay). Because multiple independent router bugs allow draining router-held ETH, the misdirected refunds become immediately stealable by any third party.

##### Details
###### Refund recipient is msg.sender
`reveal()` refunds the delta to `msg.sender`:

```solidity
if (msg.value > total) {
    SafeTransferLib.safeTransferETH(msg.sender, msg.value - total);
}
```

The same pattern exists in `renew()`.

###### Official dapp routes reveals through zRouter
The dapp computes commitments with `owner = ZROUTER` and performs the reveal via `ZROUTER.multicall(...)`, so the router becomes `msg.sender` for the `NameNFT.reveal()` call:

```javascript
const commitment = await rc.makeCommitment(name, ZROUTER, secret);
...
tx = await wcTransaction(router.multicall([
  rIface.encodeFunctionData('revealName', [pending.name, pending.secret, connectedAddress])
], { value: total }), 'Approve registration');
```

###### Concrete exploitability (remote, unprivileged)
1. A user registers a name during a non-zero premium window (or otherwise sends more than required).
2. Any refund is paid to `ZROUTER` (not the user) because `msg.sender` is the router in the reveal.
3. Any unprivileged attacker can subsequently steal that ETH if the router has any publicly-callable balance-drain primitive (multiple such primitives exist in the system’s current router).

Even ignoring downstream router-theft, users lose custody of the refund (it is no longer held by the user’s EOA/contract and is not automatically returned in the dapp’s ETH flow).

##### Impact Cascade
- Direct user fund loss: refunds that should return to the registrant are paid to `ZROUTER`.
- Forced trust dependency: users must trust the router to correctly and safely custody/return refunds.
- Immediate theft surface: any existing or future router vulnerability that extracts router ETH becomes a refund-theft vector.

##### Assumptions and Uncertainties
1. The official dapp’s router-based registration path is used in production (it is hard-coded in the dapp).
2. Overpayment/refunds occur in practice (premium decay/quote drift/user overpay).

##### Why did tests miss this issue? Why has it not been surfaced?
- The Solidity tests focus on `NameNFT` correctness in isolation and do not model the official dapp’s router-mediated reveal path.
- Unit tests for `reveal()` treat refunding `msg.sender` as benign, but in router-based flows `msg.sender` is not the economic payer.

##### Recommendation
- Contract-level: add a `revealFor(label, secret, to)` variant where the commitment binds `to` and refunds are paid to `to` (not `msg.sender`).
- Router/dapp-level: always include a final step that immediately returns router-held ETH refunds to the end user for ETH reveals (and ensure the refund mechanism cannot be hijacked).

##### References
1. https://github.com/z0r0z/wei-names/blob/49abd2bb380112a8943619228c5a727bff276c40/src/NameNFT.sol#L251-L279
2. https://github.com/z0r0z/wei-names/blob/49abd2bb380112a8943619228c5a727bff276c40/src/NameNFT.sol#L309-L327
3. https://github.com/z0r0z/wei-names/blob/49abd2bb380112a8943619228c5a727bff276c40/dapp/weiNS.html#L644-L645
4. https://github.com/z0r0z/wei-names/blob/49abd2bb380112a8943619228c5a727bff276c40/dapp/weiNS.html#L1554-L1707

> **Response:** Acknowledged, low severity — patched.
>
> The dapp computes `total = fee + premium` and sends exactly that amount, so refunds only occur if the premium decreases between the dapp reading it and the transaction landing on-chain — a narrow edge case. `renew()` is not affected — the dapp calls it directly (not through the router), so `msg.sender` is the user.
>
> The USDC and DAI reveal paths already include a `sweep(ETH, 0, 0, user)` call after `revealName` in the multicall, which returns any excess ETH to the user. The ETH reveal path was simply missing this sweep.
>
> ```diff
>      tx = await wcTransaction(router.multicall([
> -      rIface.encodeFunctionData('revealName', [pending.name, pending.secret, connectedAddress])
> +      rIface.encodeFunctionData('revealName', [pending.name, pending.secret, connectedAddress]),
> +      rIface.encodeFunctionData('sweep', [ethers.ZeroAddress, 0, 0, connectedAddress])
>      ], { value: total }), 'Approve registration');
> ```

<a id="low"></a>
## Low

<a id="finding-wns-12"></a>
### WNS-12 — Unrestricted zRouter.sweep() lets any attacker steal all ETH/ERC20/ERC6909 held by the router

#### Unrestricted zRouter.sweep() lets any attacker steal all ETH/ERC20/ERC6909 held by the router

##### Executive Summary
The system’s dapp hard-codes a deployed router (`ZROUTER`) and explicitly routes funds through it (e.g., swap-to-reveal flows where “excess ETH stays in router for sweep”). The deployed `zRouter` contract exposes a `sweep()` function that is callable by anyone and can transfer the router’s entire ETH balance and/or token balances to an arbitrary recipient. This is a direct, unprivileged, remote theft vector: any attacker can drain all ETH, ERC20 balances, and ERC6909 balances held by the router at any time.

##### Details
Code location (verified source on Etherscan): `zRouter` at `0x0000000000001C3a3Aa8FDfca4f5c0c94583aC46`.

Vulnerable function (no access control):
```solidity
function sweep(address token, uint256 id, uint256 amount, address to) public payable {
    if (token == address(0)) {
        _safeTransferETH(to, amount == 0 ? address(this).balance : amount);
    } else if (id == 0) {
        safeTransfer(token, to, amount == 0 ? balanceOf(token) : amount);
    } else {
        IERC6909(token)
            .transfer(
                to,
                id,
                amount == 0 ? IERC6909(token).balanceOf(address(this), id) : amount
            );
    }
}
```

Exploit path:
1. Observe the router has non-zero ETH or token balances (common in multi-step router flows).
2. Call `sweep(address(0), 0, 0, attacker)` to steal all ETH, and/or `sweep(token, 0, 0, attacker)` to steal all of an ERC20 balance.
3. The router transfers funds directly to the attacker-controlled address.

Root cause: `sweep()` is not restricted (no `onlyOwner`, no per-user accounting, no “refund only the caller’s dust”).

##### Impact Cascade
- Direct asset theft: any ETH held by `ZROUTER` can be drained immediately.
- Direct token theft: any ERC20/ERC6909 held by `ZROUTER` can be drained immediately.
- System breakage: router-mediated name registration flows can be disrupted (router balance drained between user actions).

##### Assumptions and Uncertainties
1. The deployed router is used in production by the system’s public UI and/or integrators (the dapp hard-codes `ZROUTER`).
2. The router can hold assets temporarily (the dapp indicates surplus ETH can remain in the router).

##### Why did tests miss this issue? Why has it not been surfaced?
The repository’s Foundry tests target `NameNFT` and do not include tests for the deployed `zRouter` contract or its interaction flows. If users only use the router in single atomic multicalls, balances may be short-lived, but any non-atomic usage or residual balances are immediately stealable.

##### Recommendation
- Restrict `sweep()` with `onlyOwner` (minimum), or remove it entirely.
- If “user refunds” are required, implement explicit per-user accounting and only allow a user to withdraw their own tracked balances.
- Avoid leaving residual balances in the router; refund within the same transaction whenever possible.

##### References
1. https://etherscan.io/address/0x0000000000001C3a3Aa8FDfca4f5c0c94583aC46#code
2. https://github.com/z0r0z/wei-names/blob/49abd2bb380112a8943619228c5a727bff276c40/dapp/weiNS.html#L644

> **Response:** Acknowledged as informational / by-design. Same class as WNS-7.
>
> `sweep()` is intentionally permissionless as part of the router's multicall-composable design. The router does not hold funds between transactions — it is designed as a transient fund holder. Funds flow through it within a single atomic multicall. Any balance sitting in the router between transactions is by-design claimable by anyone via `sweep()` as a safety valve. This is the same design pattern used by Uniswap's Universal Router and other aggregator routers.

<a id="finding-wns-9"></a>
### WNS-9 — zRouter.swapCurve exactOut refunds all router ETH+WETH to caller (cross-user drain)

#### zRouter.swapCurve exactOut refunds all router ETH+WETH to caller (cross-user drain)

##### Executive Summary
`zRouter.swapCurve` implements an “exactOut” flow and then performs a “leftover input refund”. For ETH-input routes, that refund is implemented as transferring `address(this).balance` (all ETH held by the router) to `msg.sender`, and then unwrapping and refunding the router’s entire WETH balance as ETH.

This refund logic is not scoped to “this swap’s leftover”; it refunds global router balances. Any attacker can exploit this to drain all ETH and WETH held by the router (including ETH explicitly left for later sweeping) by executing a minimal exactOut route where the swap itself consumes negligible value.

##### Details
Vulnerable code (verified source on Etherscan; extracted lines shown):

```solidity
// ---- leftover input refund (exactOut only, not chaining) ----
if (exactOut && to != address(this)) {
    if (ethIn) {
        // refund any ETH dust first:
        uint256 e = address(this).balance;
        if (e != 0) _safeTransferETH(msg.sender, e);

        // refund any *WETH* dust created by positive slippage:
        uint256 w = balanceOf(WETH);
        if (w != 0) {
            unwrapETH(w);
            _safeTransferETH(msg.sender, w);
        }
    } else {
        uint256 refund = balanceOf(firstToken);
        if (refund != 0) safeTransfer(firstToken, msg.sender, refund);
    }
}
```

Concrete exploit (drain all ETH+WETH with a “no-op” ETH<->WETH route):
- Call `swapCurve(to=attacker, exactOut=true, ...)` with a single hop using swap_type `8` (the router’s ETH<->WETH 1:1 path).
- Set `route[0] = address(0)` (ETH input), `route[1] = any non-zero address` (unused for swap_type 8), `route[2] = WETH`.
- Set `swapParams[0][2] = 8`.
- Choose `swapAmount` very small (e.g., 1 wei) and set `msg.value = amountIn`.

Because the swap_type 8 path does not interact with any pool, the call can complete while still reaching the refund branch. The refund branch then transfers *all* ETH balance currently held by the router to the attacker and unwraps+refunds *all* WETH held by the router.

Root cause: refunding `address(this).balance` / `balanceOf(WETH)` to the current caller instead of refunding only the per-call excess tracked for this swap.

##### Impact Cascade
- Total loss of router-held ETH: any attacker can drain the router’s ETH balance.
- Total loss of router-held WETH: any attacker can force-unwind and drain the router’s WETH balance.
- Cross-user theft: users who left “excess ETH in router for sweep” are directly exposed.

##### Assumptions and Uncertainties
1. The router has non-zero ETH and/or WETH at the time of attack (realistic given the router and dapp flows).
2. The call is executed with `to != address(this)` (required to hit refund branch).

##### Why did tests miss this issue? Why has it not been surfaced?
- The repository tests focus on `NameNFT` and do not cover the deployed router.
- The bug triggers when the router holds balances from prior activity (or deliberate “leave for sweep”), which may be infrequent and not covered by typical swap testing.

##### Recommendation
- Track “this call’s refundable input” explicitly (per-caller) and refund only that amount.
- Remove global balance refunds entirely; do not use `address(this).balance` / `balanceOf(WETH)` as refund sources.

##### References
1. zRouter contract (verified source): https://etherscan.io/address/0x0000000000001C3a3Aa8FDfca4f5c0c94583aC46#code
2. `swapCurve` refund block (extracted): `/tmp/d462985f-d3c4-4cf9-bc6f-a20bd3705fe2/router/src/src/zRouter.sol:668`

> **Response:** Acknowledged as informational / by-design. Same class as WNS-7.
>
> The "cross-user drain" requires funds from a different user to be in the router, which cannot happen — each transaction is atomic and the router holds zero balance between transactions. Within a single tx, `address(this).balance` and `balanceOf(WETH)` only contain the current caller's funds. The refund of the full router balance is intentional for multicall chaining where prior steps deposit ETH into the router.

<a id="finding-wns-11"></a>
### WNS-11 — zRouter snwap/snwapMulti drain router-held ERC20 when amountIn==0 by transferring balance to attacker-chosen executor

#### zRouter snwap/snwapMulti drain router-held ERC20 when amountIn==0 by transferring balance to attacker-chosen executor

##### Executive Summary
The deployed `zRouter` exposes `snwap` and `snwapMulti` as public entrypoints for an external “executor” pattern. When `amountIn == 0` and `tokenIn != address(0)`, these functions do not source tokens from the caller; instead, they transfer almost the router’s entire ERC20 balance of `tokenIn` (leaving 1 unit) to the attacker-controlled `executor` address before any meaningful checks. An unprivileged attacker can therefore drain any ERC20 balances held by the router in a single call, without needing router ownership or approvals.

##### Details
Code location (verified source on Etherscan): `zRouter` at `0x0000000000001C3a3Aa8FDfca4f5c0c94583aC46`.

Vulnerable logic (router drains its own balance to arbitrary `executor` when `amountIn == 0`):
```solidity
if (tokenIn != address(0)) {
    if (amountIn != 0) {
        safeTransferFrom(tokenIn, msg.sender, executor, amountIn);
    } else {
        unchecked {
            uint256 bal = balanceOf(tokenIn);
            if (bal > 1) safeTransfer(tokenIn, executor, bal - 1);
        }
    }
}

safeExecutor.execute{value: msg.value}(executor, executorData);
```

Exploit path (single transaction):
1. Choose an ERC20 token `tokenIn` that the router currently holds (any residual token balance from swaps, dust, or deposits).
2. Call `snwap(tokenIn, 0, recipient, tokenOut, 0, executor, "")` with `executor` set to an attacker-controlled EOA.
3. The router transfers `balanceOf(tokenIn) - 1` to the attacker-controlled `executor` immediately.
4. The call can be made to succeed by setting `amountOutMin = 0` (the post-execute slippage check will pass).

Root cause: the “use router balance when amountIn==0” branch uses `balanceOf(tokenIn)` (router’s balance) rather than a per-caller balance, and it transfers to an attacker-supplied address.

##### Impact Cascade
- Direct asset theft: drains almost all router-held ERC20 balances for any `tokenIn`.
- Cross-user impact: any user’s in-flight swap residues that remain on the router are stealable.
- Operational degradation: router-mediated flows become unreliable if third parties drain balances.

##### Assumptions and Uncertainties
1. The router can hold ERC20 balances (very plausible given it is a multi-amm router and the dapp uses it in multicalls).
2. At least one token balance is non-trivial at some point (dust or residuals are sufficient for theft).

##### Why did tests miss this issue? Why has it not been surfaced?
The repository does not include tests for the deployed `zRouter` contract. If users primarily run atomic multicalls that end with a refund, balances might be short-lived; nevertheless, any residual balance can be drained immediately.

##### Recommendation
- Remove the `amountIn == 0` branch that transfers the router’s own balance, or restrict it to owner-only maintenance.
- If “use existing router balance” is required for chaining, use transient accounting (`tstore`) and only spend amounts explicitly credited for the current call.

##### References
1. https://etherscan.io/address/0x0000000000001C3a3Aa8FDfca4f5c0c94583aC46#code

> **Response:** Acknowledged as informational / by-design. Same class as WNS-7.
>
> The `amountIn == 0` branch is intentional for multicall chaining — a previous step deposits tokens into the router, then `snwap` uses the router's balance. The router does not hold funds between transactions. `sweep()` already subsumes this attack surface more directly.

<a id="finding-wns-2"></a>
### WNS-2 — zRouter.swapV2 exactIn ETH swaps can steal router-held ETH with msg.value=0

#### zRouter.swapV2 exactIn ETH swaps can steal router-held ETH with msg.value=0

##### Executive Summary
The system’s official dapp hard-codes a deployed router (zRouter) and relies on it for swap-mediated flows. The deployed zRouter’s `swapV2()` implementation does not enforce that `msg.value` covers the ETH amount being swapped when `tokenIn == address(0)` and `exactOut == false` (exact-in). As a result, any unprivileged attacker can call `swapV2()` with `msg.value = 0` and a nonzero `swapAmount`, causing the router to fund the swap from its pre-existing ETH balance (via WETH deposit), then deliver the ERC20 output to an attacker-controlled address. This is a direct, permissionless theft primitive whenever the router has any ETH (which can happen via normal usage, mistaken transfers, or other router accounting/refund bugs).

##### Details
Code location (verified mainnet zRouter): `swapV2()` uses `amountIn = swapAmount` for exact-in swaps and, on the ETH-in path, calls `wrapETH(pool, amountIn)` without checking `msg.value >= amountIn`.

```solidity
// /tmp/759c86e6-d034-4f11-bb46-b56794458de6/zrouter-src/zRouter.flattened.sol
// swapV2(): lines ~40-111
function swapV2(
    address to,
    bool exactOut,
    address tokenIn,
    address tokenOut,
    uint256 swapAmount,
    uint256 amountLimit,
    uint256 deadline
) public payable checkDeadline(deadline) returns (uint256 amountIn, uint256 amountOut) {
    bool ethIn = tokenIn == address(0);
    if (ethIn) tokenIn = WETH;

    unchecked {
        if (!exactOut) {
            if (swapAmount == 0) {
                amountIn = ethIn ? msg.value : balanceOf(tokenIn);
                if (amountIn == 0) revert BadSwap();
            } else {
                amountIn = swapAmount;
            }
            // ... compute amountOut ...
        }

        if (!_useTransientBalance(pool, tokenIn, 0, amountIn)) {
            if (_useTransientBalance(address(this), tokenIn, 0, amountIn)) {
                safeTransfer(tokenIn, pool, amountIn);
            } else if (ethIn) {
                wrapETH(pool, amountIn); // spends router ETH even when msg.value==0
                // only refunds if msg.value > amountIn; no requirement msg.value >= amountIn
            } else {
                safeTransferFrom(tokenIn, msg.sender, pool, amountIn);
            }
        }
    }
}

// wrapETH(): lines ~1535+
function wrapETH(address pool, uint256 amount) {
    pop(call(gas(), WETH, amount, codesize(), 0x00, codesize(), 0x00));
    // transfers WETH to pool
}
```

Exploit path (permissionless):
1. Router has a non-zero ETH balance (e.g., user mistake, `receive()` donations, stranded refunds from other router flows).
2. Attacker calls `swapV2(to=attacker, exactOut=false, tokenIn=ETH, tokenOut=USDC, swapAmount=X, amountLimit=0, deadline=...)` with `msg.value = 0`.
3. Router pays the pool by wrapping `X` ETH from its own balance, then the pool sends USDC output to `to` (attacker).

Root cause: ETH-in exact-in swaps do not enforce `msg.value == amountIn` (or at least `msg.value >= amountIn`) before spending ETH via `wrapETH`.

##### Impact Cascade
- Direct theft: drains router-held ETH into attacker-controlled ERC20.
- Cross-user loss: any ETH that becomes stranded on the router becomes immediately stealable.
- System integrity: undermines any operational assumption that router balances are “safe”.

##### Assumptions and Uncertainties
1. The deployed router can hold ETH at some point (it has a payable `receive()` and other known stranding paths).
2. The attacker can choose a liquid V2 pool pair (e.g., WETH/USDC) so the swap succeeds.
3. If the router is always kept at 0 ETH, the exploit has no funds to steal (brittle invariant).

##### Why did tests miss this issue? Why has it not been surfaced?
Existing POCs and analyses tend to focus on exact-out paths and refund handling. The exact-in variant is easy to miss because `swapAmount == 0` does consult `msg.value`, but the `swapAmount > 0` exact-in branch does not.

##### Recommendation
- Enforce ETH funding invariants for ETH-in swaps, e.g. `require(msg.value == amountIn)` for exact-in.
- Never spend ambient router ETH unless it is explicitly tracked and attributable to the caller.

##### References
1. https://etherscan.io/address/0x0000000000001C3a3Aa8FDfca4f5c0c94583aC46#code
2. https://github.com/z0r0z/wei-names/blob/49abd2bb380112a8943619228c5a727bff276c40/dapp/weiNS.html#L644

> **Response:** Acknowledged as informational / by-design. Same class as WNS-7.
>
> The ETH-in path using router balance is intentional for multicall chaining (e.g., a prior swap deposits ETH into the router, then `swapV2` wraps and forwards it). The router does not hold ETH between transactions. `sweep()` already subsumes this attack surface.

<a id="finding-wns-5"></a>
### WNS-5 — swapCurve: attacker-controlled pool drains router tokens in the same transaction via lazy approve + external call

#### swapCurve: attacker-controlled pool drains router tokens in the same transaction via lazy approve + external call

##### Executive Summary
`zRouter.swapCurve()` accepts user-supplied pool addresses and, for each hop, lazily sets an unlimited allowance for the hop’s input token to that pool if the current allowance is zero. Immediately after granting this allowance, it calls the pool’s `exchange`/`add_liquidity`/`remove_liquidity_one_coin` function.

A malicious “pool” can therefore steal funds in the same transaction: during its `exchange` call, it uses the freshly granted allowance to `transferFrom(zRouter, attacker, ...)` and drain all router-held balances of the approved input token. The pool can also send a dust amount of an attacker-controlled “output token” to satisfy `swapCurve`’s output-balance check, allowing the transaction to complete.

This is a remote, permissionless theft primitive and remains exploitable even if `sweep()` were restricted, because the theft occurs during `swapCurve` execution itself.

##### Details
Affected component: deployed `zRouter` at `0x0000000000001C3a3Aa8FDfca4f5c0c94583aC46`.

Vulnerable pattern (approve then immediately call untrusted `pool`):
```solidity
// lazy approve current input token for this pool (ERC20 only)
address inToken = _isETH(curIn) ? WETH : curIn;
if (allowance(inToken, address(this), pool) == 0) {
    safeApprove(inToken, pool, type(uint256).max);
}

// ... later in the same loop
ICryptoNgPool(pool).exchange(p[0], p[1], amount, 0);
```

The `pool` address is taken directly from the user-provided `route[]` array.

Exploit sketch (single transaction):
1. Attacker identifies a token `T` that `zRouter` currently holds (or expects to hold during normal flows).
2. Attacker deploys a malicious pool contract `P` that implements the called selector (e.g. `exchange(...)`).
3. Attacker calls `swapCurve(...)` with `route[0] = T` and `route[1] = P` (and sets subsequent route entries so the function runs at least one hop).
4. Inside `swapCurve`, `zRouter` sets `allowance(T, P) = type(uint256).max` (if it was 0).
5. `zRouter` then calls `P.exchange(...)`.
6. In `P.exchange`, attacker executes `T.transferFrom(zRouter, attacker, T.balanceOf(zRouter))` (draining the router). Then `P` transfers a dust amount of an attacker-controlled output token to `zRouter` so `outBalAfter > outBalBefore` holds and `swapCurve` does not revert.

Root cause: `swapCurve` treats untrusted pool addresses as Curve pools and grants them unbounded allowances, then immediately calls them, enabling same-transaction exfiltration.

##### Impact Cascade
- Direct theft: drains any ERC20 balances held by `zRouter` for the hop input token.
- Cross-user loss: router-held balances sourced from other users’ swaps/registrations can be stolen.
- Hard to mitigate at the UI layer: the exploit is a pure on-chain call to a public function.

##### Assumptions and Uncertainties
1. `zRouter` holds non-trivial ERC20 balances at some point (likely, given multi-step router flows and known “stranded balance” issues already present).
2. The attacker can craft `route`/`swapParams` that cause `swapCurve` to reach at least one hop without reverting (achievable by using an attacker-controlled pool and attacker-controlled “output” token for balance-delta satisfaction).

##### Why did tests miss this issue? Why has it not been surfaced?
The repo’s test focus is the `NameNFT` naming system. There is no unit/integration test coverage for the deployed `zRouter`’s `swapCurve` behavior under malicious pool addresses.

##### Recommendation
- Do not approve arbitrary `pool` addresses supplied by the caller.
- If `swapCurve` must support multiple Curve pool types, restrict `pool` to a vetted allowlist (similar to `execute`’s trust model) and/or compute pool addresses deterministically.
- Approve exact amounts (or use Permit2 pull patterns) and avoid granting `type(uint256).max` allowances to external contracts.

##### References
1. https://etherscan.io/address/0x0000000000001C3a3Aa8FDfca4f5c0c94583aC46#code

> **Response:** Acknowledged as informational / by-design. Same class as WNS-7.
>
> The router does not hold funds between transactions, so the persistent approval does not create practical attack surface. The lazy `type(uint256).max` approval to user-supplied pool addresses is the **same pattern used by the official Curve Swap Router** ([0x99a5848...](https://etherscan.io/address/0x99a58482bd75cbab83b27ec03ca68ff489b5788f#code)):
>
> ```vyper
> if not self.is_approved[input_token][swap]:
>     raw_call(input_token, _abi_encode(swap, MAX_UINT256, method_id=method_id("approve(address,uint256)")), ...)
> ```
>
> This is standard Curve router design — user-supplied `swap` address from the route array, max approval, cached.

<a id="finding-wns-3"></a>
### WNS-3 — zRouter.swapV3 exactOut (ETH-in) can be executed with msg.value=0 via callback wrapETH, spending router-held ETH

#### zRouter.swapV3 exactOut (ETH-in) can be executed with msg.value=0 via callback wrapETH, spending router-held ETH

##### Executive Summary
The deployed `zRouter` supports Uniswap V3 swaps and implements the V3 swap callback in its `fallback()`. For **exact-out** swaps where `tokenIn = ETH`, the router does not require the caller to provide ETH input via `msg.value`. Instead, during the callback it will pay the pool by calling `wrapETH(pool, amountRequired)`, which draws from the router’s existing ETH balance. A remote, unprivileged attacker can therefore execute `swapV3` with `msg.value = 0` to convert any ETH sitting on the router into arbitrary ERC20 output and receive it at an attacker-controlled `to` address.

##### Details
Vulnerable pattern spans `swapV3` and the callback handler:

```solidity
// swapV3 encodes ethIn and triggers pool.swap(...)
IV3Pool(pool).swap(..., abi.encodePacked(ethIn, ethOut, msg.sender, tokenIn, tokenOut, to, swapFee));

// In the UniswapV3 callback (fallback):
if (_useTransientBalance(address(this), tokenIn, 0, amountRequired)) {
    safeTransfer(tokenIn, pool, amountRequired);
} else if (ethIn) {
    wrapETH(pool, amountRequired);
} else {
    safeTransferFrom(tokenIn, payer, pool, amountRequired);
}
```

- For ETH-in exact-out swaps, `amountRequired` is not bound to `msg.value`.
- When `ethIn == true`, the callback wraps and transfers `amountRequired` ETH from the router to the pool.

Exploit sketch (unprivileged attacker):
1. Wait until `zRouter` has a non-zero ETH balance (it has `receive()` and is referenced by the official dapp).
2. Call `swapV3(to=attacker, exactOut=true, swapFee=..., tokenIn=address(0), tokenOut=any, swapAmount=desiredOut, amountLimit=0, deadline=...)` with `msg.value=0`.
3. The router funds the pool input in the callback using router-held ETH; the pool sends `tokenOut` to `attacker`.

Root cause: the ETH-in callback payment path (`wrapETH`) is reachable even when the caller provides insufficient `msg.value`, so the router subsidizes swaps from its own ETH balance.

##### Impact Cascade
- Direct theft: drains router-held ETH by converting it into attacker-received tokenOut.
- Amplification: attacker can pick liquid pairs to quickly realize value.
- Cross-user loss: any ETH retained on the router from other users becomes attacker-extractable.

##### Assumptions and Uncertainties
1. Router holds enough ETH to cover `amountRequired` for the chosen exact-out swap.
2. The targeted Uniswap V3 pool exists and swap parameters are valid.

##### Why did tests miss this issue? Why has it not been surfaced?
- V3 tests often cover refund logic or slippage bounds, but not the “ETH-in exact-out underpayment” branch where funding occurs inside the callback.
- The bug becomes exploitable only when the router accumulates ETH from real usage patterns.

##### Recommendation
- For ETH-in exact-out swaps, enforce `msg.value >= amountIn` (or an upper bound) and ensure the callback never wraps more ETH than provided for the swap.
- Alternatively, pre-wrap exactly `msg.value` (or exact required) before calling `pool.swap` and ensure the callback only uses transient balances, never `address(this).balance`.

##### References
1. [wei-names/dapp/weiNS.html#L644](https://github.com/z0r0z/wei-names/blob/49abd2bb380112a8943619228c5a727bff276c40/dapp/weiNS.html#L644)
2. [Etherscan zRouter code](https://etherscan.io/address/0x0000000000001C3a3Aa8FDfca4f5c0c94583aC46#code)

> **Response:** Acknowledged as informational / by-design. Same class as WNS-7.
>
> The callback `wrapETH` path is intentional for multicall chaining — a prior step may deposit ETH into the router for the V3 swap to use. The router does not hold ETH between transactions. `sweep()` already subsumes this attack surface.

<a id="finding-wns-6"></a>
### WNS-6 — zRouter.swapCurve exactOut refunds router-held ERC20 input balance to caller (cross-user drain)

#### zRouter.swapCurve exactOut refunds router-held ERC20 input balance to caller (cross-user drain)

##### Executive Summary
`zRouter.swapCurve()` implements an exact-out mode that refunds leftover *input* after completing Curve hops. For non-ETH inputs, the refund is computed as `balanceOf(firstToken)` and transferred to `msg.sender`. This uses the router’s *entire* current ERC20 balance for `firstToken`, not the per-call leftover.

Any unprivileged caller can therefore drain all router-held balances of an arbitrary ERC20 chosen as `firstToken` (e.g., USDC/DAI) as long as the router has a positive balance at the end of the call. In practice, routers often accumulate balances from dust, prior user flows, refunds, or operational mistakes; once any balance exists, it becomes extractable by the next attacker calling `swapCurve` exact-out.

##### Details
Code location (deployed router source as verified by Etherscan; extracted locally as `/tmp/zRouter.sol`):

```solidity
// ---- leftover input refund (exactOut only, not chaining) ----
if (exactOut && to != address(this)) {
    if (ethIn) {
        ...
    } else {
        // non-ETH inputs already use `firstToken`:
        uint256 refund = balanceOf(firstToken);
        if (refund != 0) safeTransfer(firstToken, msg.sender, refund);
    }
}
```

The refund logic is not bounded to the input that was provided for this swap. It refunds whatever `balanceOf(firstToken)` the router holds after the route execution, which can include unrelated balances accumulated from other users.

##### Exploit Walkthrough
1. Assume the router holds `X > 0` of some ERC20 `T` (e.g., USDC) from any source.
2. Attacker calls `swapCurve(to=attacker, exactOut=true, route[0]=T, ...)` such that the swap consumes only a small amount of `T` (or any amount ≤ the attacker’s provided max).
3. After completing the swap and delivering output, the function executes the non-ETH exactOut refund branch and transfers the router’s entire remaining `T` balance to `msg.sender`.
4. Attacker receives essentially all `T` held by the router (minus the amount spent inside the Curve pools).

##### Impact Cascade
- Direct fund loss: complete theft of any ERC20 balance held by `zRouter` for attacker-chosen `firstToken`.
- Cross-user impact: any user funds that become stranded in the router become a public prize.
- Exploit composability: the drain can be repeated for each token the router holds.

##### Assumptions and Uncertainties
1. The router holds a non-zero balance of the targeted ERC20 at the time of attack (a realistic condition for long-lived routers).
2. At least one valid Curve route exists for the chosen `firstToken` so the call reaches the refund branch.

##### Why did tests miss this issue? Why has it not been surfaced?
Existing PoCs/focus heavily cover ETH/WETH exactOut refund and other router drain paths; this ERC20-specific exactOut refund is easy to overlook because the ETH branch is more obviously dangerous. It also requires the router to already hold ERC20 balances, which depends on ecosystem usage and other integration behaviors.

##### Recommendation
- Track the per-call input amount and refund only `amountLimit - amountIn` (or an equivalent per-swap leftover), not `balanceOf(firstToken)`.
- If supporting router-internal chaining, avoid any refund logic that references global router balances.

##### References
1. `/tmp/zRouter.sol:674`
2. `/tmp/zRouter.sol:689`

> **Response:** Acknowledged as informational / by-design. Same class as WNS-7, WNS-9.
>
> The refund uses `balanceOf(firstToken)` which within a single atomic transaction only contains the current caller's funds. "Cross-user drain" requires funds from a different user to be in the router, which cannot happen — each transaction is atomic and the router holds zero balance between transactions.
