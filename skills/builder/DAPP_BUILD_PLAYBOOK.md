# dApp Build Playbook

From spec file to finished decentralized application. Every step, every command, every verification.

---

## How This Document Works

This playbook is sequential. Each stage has:
- **What you do** — the work
- **What you produce** — the deliverable
- **How you verify** — the pass condition
- **When you stop** — the explicit boundary

Do not skip stages. Do not combine stages. A stage either passes or it doesn't — you know exactly what broke and where.

---

## Prerequisites

### Tools Required
```
node >= 18          # runtime
yarn                # package manager (SE2 uses yarn workspaces)
foundry (forge)     # Solidity compiler, deployer, verifier
git                 # version control
gh                  # GitHub CLI (authenticated)
cast                # EVM CLI from foundry (calls, sends, decodes)
npx                 # for create-eth, bgipfs, tsx
```

### Accounts & Secrets
```
PRIVATE_KEY         # deployer wallet private key
ALCHEMY_RPC_URL     # dedicated RPC endpoint (never public RPCs)
BGIPFS_TOKEN        # bgipfs upload token
```

All secrets live in `.env`. Never commit it. Never cat/read it in a tool that logs output. To check a value exists: `grep KEY_NAME .env | cut -d= -f2`.

### RPC Rule

Never use `mainnet.base.org`, `base.llamarpc.com`, `eth.llamarpc.com`, or any public RPC. Always Alchemy endpoints with an API key. If `ALCHEMY_RPC_URL` is not available, stop and get it — do not fall back.

---

## Stage 0 — Read the Spec

**What you do:** Read everything about the job before writing a single line of code.

### 0.1 Read the Job Description
The spec comes from the client. It may be a build plan, a paragraph, or a detailed architecture doc. Read it completely. Identify:
- What contracts are needed (names, functions, interactions)
- What external protocols are involved (Uniswap, Lido, Chainlink, etc.)
- What the frontend should look like and do
- Who the client is (their wallet address = owner of everything you deploy)
- What chain to deploy on (default: Base, chain ID 8453)

### 0.2 Read All Messages
```bash
curl -s https://leftclaw.services/api/job/<id>/messages
```
Clients post requirements, preferences, aesthetic choices, and scope changes via chat AFTER the job description is written. The on-chain description is the baseline; messages can override it entirely.

**Lesson learned (Job #39):** Client posted a "Windows 95 aesthetic" requirement via chat. The on-chain description said nothing about it. Skipping messages would have shipped a completely wrong frontend.

### 0.3 Identify Key Addresses
Before writing any code, collect every address you'll need:
- Client wallet (owner of all deployed contracts)
- Token contracts (addresses, decimals, standard behaviors)
- Protocol contracts (routers, pools, oracles, factories)
- Chain-specific addresses (WETH, bridge contracts)

Verify each address exists on the target chain:
```bash
cast code <address> --rpc-url $ALCHEMY_RPC_URL
```
If it returns `0x`, the contract doesn't exist on that chain.

### 0.4 Identify External Protocol Behaviors
For each external protocol:
- Is the token standard ERC20? Any non-standard behaviors (rebasing, fee-on-transfer, blocklist)?
- What pool fee tiers exist? (Uniswap V3: 100, 500, 3000, 10000)
- Is the protocol available on the target chain? (e.g., Lido's wstETH on Base is bridged, not native)
- What are the correct interface function signatures?

**Deliverable:** A mental model of what you're building, who it's for, and every external dependency.

**Pass condition:** You can explain the full user flow, every contract interaction, and every external protocol integration from memory.

---

## Stage 1 — Scaffold + Repo

**What you do:** Create the project skeleton.

### 1.1 Scaffold
```bash
cd ~/clawd/ethereum-servicer/builds/
npx create-eth@latest --project leftclaw-service-job-<JOBID> --solidity-framework foundry --skip-git
```

This creates:
```
leftclaw-service-job-<JOBID>/
  packages/
    foundry/          # Contracts, scripts, tests
      contracts/
      script/
      test/
      foundry.toml
    nextjs/           # Frontend
      app/
      components/
      contracts/      # deployedContracts.ts, externalContracts.ts
      hooks/
      styles/
      scaffold.config.ts
  package.json
```

### 1.2 Initialize Git + GitHub
```bash
cd ~/clawd/ethereum-servicer/builds/leftclaw-service-job-<JOBID>
git init
git config user.name "clawdbotatg"
git config user.email "clawdbotatg@users.noreply.github.com"
git add -A
git commit -m "feat: scaffold SE2 Foundry for <project-name>"
gh repo create clawdbotatg/leftclaw-service-job-<JOBID> --public --source=. --remote=origin --push
```

### 1.3 Verify
- [ ] `packages/foundry` exists
- [ ] `packages/nextjs` exists
- [ ] `forge build` compiles the default YourContract.sol
- [ ] Repo visible at `https://github.com/clawdbotatg/leftclaw-service-job-<JOBID>`

**Deliverable:** Repo path on disk, GitHub URL.

**Stop condition:** Do NOT write PLAN.md, contracts, or frontend. Stop at scaffold.

---

## Stage 2 — Build Plan

**What you do:** Write the architecture document.

### 2.1 Write PLAN.md
Create `PLAN.md` in the repo root covering:

```markdown
# Build Plan: <Project Name>

## Overview
What we're building and why.

## Smart Contracts
For each contract:
- Name and purpose
- Key functions (with signatures)
- Storage variables
- Events
- Access control (who can call what)
- External protocol interactions

## External Integrations
For each external protocol:
- Contract address on target chain
- Which functions we call
- Interface requirements
- Risk notes (bridge risk, oracle trust assumptions, etc.)

## Frontend
- Pages and sections
- User flows (connect → action → result)
- What data is read from which contract
- Approval flows needed

## Security Considerations
- Attack vectors specific to this design
- Mitigations planned
- Trust assumptions

## Deployment Plan
- Order of deployment (dependencies matter)
- Constructor arguments for each contract
- Post-deploy configuration steps
- Ownership: ALL privileged roles → client address

## Client
- Address: <client wallet>
- Receives ownership of all contracts
```

### 2.2 Write USERJOURNEY.md
Create `USERJOURNEY.md` covering:
- Every happy path (step by step: what user sees, clicks, what happens)
- Every edge case (no wallet, wrong network, zero balance, insufficient allowance, tx rejected, tx failed)
- Every approval flow (which token, which spender, the two-state pattern)

This document guides the builder AND every auditor.

### 2.3 Commit
```bash
git add PLAN.md USERJOURNEY.md
git commit -m "docs: add build plan and user journey"
git push
```

**Deliverable:** PLAN.md and USERJOURNEY.md pushed to repo.

**Stop condition:** Do NOT write any code.

---

## Stage 3 — Write Contracts (Compile Only)

**What you do:** Implement all smart contracts. Compile. Do not deploy.

### 3.1 Delete Scaffold Defaults
```bash
rm packages/foundry/contracts/YourContract.sol
rm packages/foundry/script/DeployYourContract.s.sol
rm packages/foundry/test/YourContract.t.sol
```

### 3.2 Write Contracts

Place all contracts in `packages/foundry/contracts/`. Use `pragma solidity ^0.8.20;` to match OpenZeppelin 5.x.

**Mandatory patterns:**
- `Ownable2Step` (not `Ownable`) — prevents accidental ownership transfer
- `ReentrancyGuard` on every function that makes external calls
- `SafeERC20` for all token operations (`safeTransfer`, `safeTransferFrom`, `forceApprove`)
- CEI pattern (Checks-Effects-Interactions) — update state before external calls
- Constructor sets `owner = clientAddress` (or uses deployer-first pattern — see Deploy stage)

**ERC4626 vaults specifically:**
- `_decimalsOffset()` >= 3 for inflation attack prevention (virtual shares)
- Track principal separately from yield if yield is redirected
- Clamp principal to totalAssets() before yield calculations

**Uniswap V3 swaps specifically:**
- Always set `amountOutMinimum` > 0 (slippage protection)
- Always set `deadline` (block.timestamp for on-chain; caller-provided for keeper txs)
- TWAP oracle check BEFORE the swap, not after
- Wrap `pool.observe()` in try/catch (new pools may lack observation history)

**Access control:**
- Owner = client address
- If a keeper/harvester role is needed, add it as a separate role the owner can set
- Walkaway test: if the owner disappears, can users still withdraw their funds? The answer must be yes.

### 3.3 Write Interfaces
Create `packages/foundry/contracts/interfaces/` for external protocol interfaces. Only include the functions you actually call.

### 3.4 Write Deploy Script
Create `packages/foundry/script/Deploy<ProjectName>.s.sol`:

```solidity
// Deploy pattern for multi-contract systems:
// 1. Deploy with deployer as initial owner
// 2. Configure cross-references (setHarvester, setRewardsDistributor, etc.)
// 3. Transfer ownership to client via transferOwnership()
// Client must call acceptOwnership() on each contract (Ownable2Step)
```

The deployer-first pattern is critical: you can't configure cross-references after transferring ownership because only the owner can call admin functions.

### 3.5 Register External Contracts
Update `packages/nextjs/contracts/externalContracts.ts` with any tokens or protocols the frontend reads:
```typescript
export default {
  8453: {  // Base chain ID
    CLAWD: {
      address: "0x...",
      abi: [/* standard ERC20 ABI */],
    },
  },
} as const;
```

### 3.6 Compile
```bash
cd packages/foundry && forge build
```

### 3.7 Verify
- [ ] `forge build` exits 0, no errors
- [ ] All contracts have ReentrancyGuard, Ownable2Step, SafeERC20
- [ ] Deploy script deploys in correct order with correct constructor args
- [ ] External contracts registered in externalContracts.ts

**Deliverable:** Contract source files, passing `forge build`.

**Stop condition:** Do NOT deploy. Do NOT write frontend code.

---

## Stage 4 — Contract Audit

**What you do:** Audit every contract. File GitHub issues. Do not fix anything.

### 4.1 Standard Audit
Read every contract file. Check:

**Critical checks:**
1. Reentrancy — guards on all external-calling functions
2. Access control — no leftover deployer privileges, Ownable2Step correct
3. Integer safety — overflow/underflow, unsafe casting
4. External call safety — return values checked, CEI pattern followed
5. Token handling — SafeERC20, no raw transfer()
6. Slippage protection — all swaps have minimum output
7. Oracle safety — TWAP checks, manipulation resistance
8. First depositor attacks — virtual shares for ERC4626

**DeFi-specific checks (if applicable):**
9. Flash loan vectors — can someone manipulate state in a single block?
10. Sandwich attack vectors — are swaps protected?
11. Yield accounting — can principal and yield drift?
12. Walkaway safety — can users always withdraw?
13. Price manipulation — spot price vs TWAP divergence

### 4.2 File Issues
```bash
gh label create "job-<ID>" --repo clawdbotatg/leftclaw-service-job-<ID> --color "0e8a16" --force
gh label create "contract-audit" --repo clawdbotatg/leftclaw-service-job-<ID> --color "d93f0b" --force

# For each Medium+ finding:
gh issue create --repo clawdbotatg/leftclaw-service-job-<ID> \
  --title "[SEVERITY] Finding title" \
  --body "**Location:** file:function\n**Description:** ...\n**Recommendation:** ..." \
  --label "job-<ID>,contract-audit"
```

### 4.3 Deep Audit (for complex contracts)
Run a deep audit if the contracts involve:
- Token swaps or AMM interactions
- Multi-contract interactions
- Financial logic (lending, staking, vaults)
- Upgradeable proxies
- > 200 lines of Solidity

Deep audit focuses on:
- Cross-contract interaction risks
- Pool observation history requirements
- Zero-staker edge cases in rewards contracts
- Principal tracking drift over many operations
- Rounding errors at scale

**Deliverable:** Audit report with every finding (severity, location, description, recommendation). GitHub issues filed for Medium+.

**Stop condition:** Do NOT fix anything. Report only.

---

## Stage 5 — Contract Fixes

**What you do:** Fix every finding from the audit.

### 5.1 Fix by Severity
1. **Critical** — must fix, no exceptions
2. **High** — must fix
3. **Medium** — fix or document as accepted with clear reasoning
4. **Low** — fix if trivial, otherwise document
5. **Info** — no action required

### 5.2 Recompile
```bash
cd packages/foundry && forge build
```

### 5.3 Close Issues
```bash
gh issue close <num> --repo clawdbotatg/leftclaw-service-job-<ID> \
  --comment "Fixed in commit <hash>"
```

### 5.4 Verify
- [ ] `forge build` exits 0
- [ ] Zero Critical/High findings remain open
- [ ] Every Medium finding is either fixed or documented as accepted

**Deliverable:** Itemized response to every finding, passing build.

**Stop condition:** Do NOT deploy.

---

## Stage 6 — Deploy + Verify

**What you do:** Deploy contracts to the target chain. Verify on block explorer.

### 6.1 Configure RPC
In `packages/foundry/foundry.toml`:
```toml
[rpc_endpoints]
base = "${ALCHEMY_RPC_URL}"
```
NEVER use `https://mainnet.base.org`.

### 6.2 Deploy
```bash
source .env
yarn deploy --network base --file Deploy<ProjectName>.s.sol
```

Or direct forge:
```bash
cd packages/foundry
forge script script/Deploy<ProjectName>.s.sol \
  --rpc-url $ALCHEMY_RPC_URL \
  --private-key $PRIVATE_KEY \
  --broadcast \
  --verify
```

### 6.3 Verify
```bash
yarn verify --network base
```

No Basescan API key needed — SE2 has this built in.

If that fails, verify individually:
```bash
forge verify-contract <ADDRESS> <CONTRACT_NAME> --chain-id 8453 --watch
```

### 6.4 Verify On-Chain State
For every deployed contract, verify the configuration:
```bash
source .env
# Check ownership
cast call <address> "owner()(address)" --rpc-url $ALCHEMY_RPC_URL
cast call <address> "pendingOwner()(address)" --rpc-url $ALCHEMY_RPC_URL

# Check cross-references
cast call <vault> "harvester()(address)" --rpc-url $ALCHEMY_RPC_URL
# ... verify each cross-reference matches expected contract
```

### 6.5 Verify deployedContracts.ts
Check that `packages/nextjs/contracts/deployedContracts.ts` was auto-generated with the correct addresses and ABIs. If `yarn deploy` was used, this happens automatically. If `forge script` was used directly, you may need to regenerate it.

### 6.6 Verify
- [ ] All contracts deployed (addresses recorded)
- [ ] All contracts verified on Basescan (green checkmark)
- [ ] `deployedContracts.ts` updated with real addresses
- [ ] Cross-references configured (harvester, distributor, etc.)
- [ ] Ownership transfer initiated to client address

**Deliverable:** Contract addresses, Basescan links, verification status.

**Stop condition:** Do NOT write frontend code.

---

## Stage 7 — Frontend Build

**What you do:** Implement the full UI. Run `yarn build`. Do not deploy to IPFS.

### 7.1 Configuration
Before writing any components:

**scaffold.config.ts:**
```typescript
targetNetworks: [chains.base],
pollingInterval: 3000,  // NOT 30000
```

**wagmiConnectors.tsx:**
- Change `appName: "scaffold-eth-2"` to `appName: "<your-app-name>"`
- Add `phantomWallet` to the wallets array:
```typescript
import { phantomWallet } from "@rainbow-me/rainbowkit/wallets";
// Add to wallets array
```

**foundry.toml** (if not already done):
```toml
[rpc_endpoints]
base = "${ALCHEMY_RPC_URL}"
```

### 7.2 SE2 Branding Cleanup

This is not optional. Every item must be addressed.

**Footer.tsx:**
- Remove "Fork me" link
- Remove "Built with heart at BuidlGuidl"
- Remove "Support" links
- Remove `nativeCurrencyPrice` badge (it renders ETH price on ALL networks including Base mainnet, not just local)
- Replace with your project's footer content

**Header.tsx:**
- Replace SE2 logo and "Scaffold-ETH" text with project name
- Remove "Debug Contracts" nav link
- Keep the RainbowKit connect button

**getMetadata.ts:**
- Change `titleTemplate: "%s | Scaffold-ETH 2"` to `"%s | <YourApp>"`
- Change default title to your app name
- Change description
- Use `process.env.NEXT_PUBLIC_PRODUCTION_URL` for OG image base URL (not `VERCEL_PROJECT_PRODUCTION_URL`)

**README.md:**
- Replace entirely with project content (architecture, contract addresses, how to run locally)
- Do NOT leave the SE2 template README

**Favicon:**
- Replace `packages/nextjs/public/favicon.ico` or add `favicon.svg`

**manifest.json:**
- Update `packages/nextjs/public/manifest.json` — change "Scaffold-ETH 2 DApp" to your app name

**Block explorer:**
- Rename `packages/nextjs/app/blockexplorer` to `app/_blockexplorer-disabled`
- The block explorer uses `localStorage` at import time and crashes static export

### 7.3 Styling

**globals.css — DaisyUI theme:**
- Change `--radius-field: 9999rem` to `--radius-field: 0.5rem` in BOTH theme blocks (light and dark)
- If the spec calls for a specific aesthetic (terminal, retro, etc.), set both themes to match

**Dark mode rule:**
- NEVER hardcode dark backgrounds (`bg-[#0a0a0a]`, `bg-black`, `bg-zinc-900`)
- Use DaisyUI semantic variables: `bg-base-100`, `bg-base-200`, `text-base-content`
- Exception: if the design is intentionally dark-only, force `data-theme="dark"` on `<html>` AND remove the `<SwitchTheme/>` component

### 7.4 The Page — Wallet Flow

Every page with write operations MUST implement the four-state flow. Show ONE button at a time:

```
1. Not connected  → "Connect Wallet" button (useConnectModal)
2. Wrong network  → "Switch to Base" button (useSwitchChain)
3. Needs approval → "Approve" button
4. Ready          → Action button
```

```tsx
import { useConnectModal } from "@rainbow-me/rainbowkit";
import { useAccount, useChainId, useSwitchChain } from "wagmi";
import { base } from "viem/chains";

const { isConnected } = useAccount();
const chainId = useChainId();
const { switchChain } = useSwitchChain();
const { openConnectModal } = useConnectModal();

// In render:
if (!isConnected) return <button onClick={() => openConnectModal?.()}>Connect Wallet</button>;
if (chainId !== base.id) return <button onClick={() => switchChain({ chainId: base.id })}>Switch to Base</button>;
if (!hasAllowance) return <ApproveButton />;
return <ActionButton />;
```

### 7.5 The Approval Flow — Two-State Pattern

This is the single most important UX pattern. `isPending` from wagmi drops to `false` when the wallet returns the tx hash — NOT when the tx confirms on-chain. This creates a window where users can double-approve.

```tsx
const [approvalSubmitting, setApprovalSubmitting] = useState(false);
const [approvalCooldown, setApprovalCooldown] = useState(false);

const handleApprove = async () => {
  if (approvalSubmitting || approvalCooldown) return;   // guard
  setApprovalSubmitting(true);                           // lock immediately
  try {
    await writeApprove({
      functionName: "approve",
      args: [spenderAddress, amount],
    });
    // TX confirmed on-chain at this point
    setApprovalCooldown(true);
    setTimeout(() => {
      setApprovalCooldown(false);
      refetchAllowance();
    }, 4000);
  } catch (err) {
    handleError(err);
  } finally {
    setApprovalSubmitting(false);                        // MUST be in finally
  }
};

// Button:
<button
  disabled={isPending || approvalSubmitting || approvalCooldown}
  onClick={handleApprove}
>
  {approvalCooldown ? "Confirming..." : "Approve"}
</button>
```

**Why `finally`:** If the user rejects the tx in their wallet, `approvalSubmitting` must be cleared. Without `finally`, a rejected tx locks the button permanently.

**Why `approvalCooldown`:** After `writeContractAsync` resolves, the tx is confirmed but the node's cache may not reflect the new allowance yet. The 4-second cooldown + refetch ensures the UI reads the updated state.

### 7.6 Mobile Deep Linking

RainbowKit/WalletConnect does NOT auto-open the wallet app on mobile. You must do it yourself.

**Pattern:** Fire the TX first, then deep link after a delay.

```tsx
const triggerMobileDeepLink = useCallback(() => {
  if (typeof window === "undefined") return;
  const isMobile = /iPhone|iPad|iPod|Android/i.test(navigator.userAgent);
  if (!isMobile || window.ethereum) return; // skip if desktop or in-app browser
  setTimeout(() => {
    window.location.href = "metamask://"; // or detect wallet from connector
  }, 2000);
}, []);

// Usage — wrap EVERY write call:
const handleAction = async () => {
  const promise = writeContract({ functionName: "doThing", args: [...] });
  triggerMobileDeepLink();
  await promise;
};
```

**Never** deep link before the TX. The wallet won't have a request to show.

### 7.7 Error Handling

Every `catch` block must show a user-facing notification:
```tsx
import { notification } from "~~/utils/scaffold-eth";

const handleError = (err: unknown) => {
  const msg = err instanceof Error ? err.message : String(err);
  if (msg.includes("rejected") || msg.includes("denied")) {
    notification.error("Transaction rejected");
  } else {
    notification.error("Transaction failed. Please try again.");
  }
};
```

Never `console.error(err)` alone. Users can't see the console.

### 7.8 SE2 Hooks Reference
```tsx
// READ from contract
const { data } = useScaffoldReadContract({
  contractName: "MyContract",
  functionName: "myFunction",
  args: [arg1, arg2],
});

// WRITE to contract
const { writeContractAsync, isPending } = useScaffoldWriteContract({
  contractName: "MyContract",
});
await writeContractAsync({
  functionName: "myFunction",
  args: [arg1],
  value: parseEther("0.01"), // for payable
});

// External contracts (from externalContracts.ts)
const { data: balance } = useScaffoldReadContract({
  contractName: "CLAWD",  // name from externalContracts.ts
  functionName: "balanceOf",
  args: [address],
});
```

### 7.9 Display Components
```tsx
import { Address } from "@scaffold-ui/components";
import { AddressInput } from "@scaffold-ui/components";

// Display an address (ENS, blockie, explorer link, copy)
<Address address={contractAddress} chain={base} />

// Input an address (ENS resolution, validation, paste handling)
<AddressInput value={addr} onChange={setAddr} placeholder="0x... or ENS" />
```

**Every displayed address → `<Address/>`**
**Every address input → `<AddressInput/>`**
Never raw text for either.

### 7.10 Number Formatting
```tsx
import { formatUnits, parseUnits, formatEther, parseEther } from "viem";

// Display: BigInt → human readable
formatEther(weiAmount)           // "1.5" (18 decimals)
formatUnits(usdcAmount, 6)       // "100.0" (6 decimals)

// Input: human readable → BigInt
parseEther("1.5")                // 1500000000000000000n
parseUnits("100", 6)             // 100000000n
```

Never display raw BigInt values to users.

### 7.11 Polyfill for Static Export (Node 25+)
Create `packages/nextjs/polyfill-localstorage.cjs`:
```javascript
if (typeof globalThis.localStorage === "undefined") {
  const store = {};
  globalThis.localStorage = {
    getItem: (k) => store[k] ?? null,
    setItem: (k, v) => { store[k] = String(v); },
    removeItem: (k) => { delete store[k]; },
    clear: () => { Object.keys(store).forEach(k => delete store[k]); },
    get length() { return Object.keys(store).length; },
    key: (i) => Object.keys(store)[i] ?? null,
  };
}
```

**Must be in `packages/nextjs/`** — not the project root. The build command runs in the nextjs package context.

### 7.12 Build
```bash
yarn next:build
```

### 7.13 Verify
- [ ] `yarn next:build` exits 0
- [ ] `packages/nextjs/out/` directory exists with content
- [ ] No SE2 branding in: Footer, Header, title, README, favicon, manifest.json
- [ ] `appName` changed in wagmiConnectors.tsx
- [ ] `pollingInterval: 3000` in scaffold.config.ts
- [ ] `--radius-field: 0.5rem` in both theme blocks
- [ ] Block explorer disabled/removed

**Deliverable:** Passing frontend build.

**Stop condition:** Do NOT upload to IPFS.

---

## Stage 8 — Frontend QA Audit

**What you do:** Audit the frontend against the full QA checklist. Do not fix anything.

### Ship-Blockers (ALL must PASS)

| # | Check | How to Verify |
|---|-------|---------------|
| 1 | Wallet connect shows a BUTTON, not text | Read page.tsx — look for `openConnectModal` or `RainbowKitCustomConnectButton` |
| 2 | Wrong network shows Switch button | Look for `chainId !== base.id` check before action buttons |
| 3 | Approve button has two-state protection | Grep for `approvalSubmitting` AND `approvalCooldown` — both must exist |
| 4 | Contracts verified on block explorer | Check each address on Basescan — green checkmark |
| 5 | SE2 footer branding removed | Read Footer.tsx — no BuidlGuidl, Fork me, Support, nativeCurrencyPrice |
| 6 | SE2 tab title removed | Read getMetadata.ts — no "Scaffold-ETH 2" |
| 7 | SE2 README replaced | Read README.md — project content, not template |
| 8 | Favicon replaced | Check public/favicon.* — not SE2 default |

### Should-Fix (ALL must PASS)

| # | Check | How to Verify |
|---|-------|---------------|
| 9 | Contract address displayed with `<Address/>` | Grep for `<Address` in page.tsx |
| 10 | OG image absolute URL | Read getMetadata.ts — uses `NEXT_PUBLIC_PRODUCTION_URL` |
| 11 | `--radius-field: 0.5rem` | Read globals.css — both theme blocks |
| 12 | Token amounts have USD context | Check every amount display — or mark N/A for community tokens |
| 13 | Errors show user-facing messages | Check every catch block — must call `notification.error()` |
| 14 | Phantom wallet in RainbowKit | Read wagmiConnectors.tsx — `phantomWallet` in list |
| 15 | Mobile deep linking | Grep for `metamask://` or `openWallet` — must fire AFTER tx |
| 16 | `appName` changed | Read wagmiConnectors.tsx — not "scaffold-eth-2" |
| 17 | Four-state action flow | Check each action panel — one button at a time |
| 18 | Address inputs use `<AddressInput/>` | `grep -rn 'type="text"' packages/nextjs/app/ \| grep -i "addr\|0x"` |
| 19 | Token amounts formatted | No raw BigInt display — `formatUnits`/`formatEther` used |
| 20 | pollingInterval 3000 | Read scaffold.config.ts |
| 21 | Block explorer disabled | Check `app/blockexplorer` doesn't exist |
| 22 | Button loading text not DaisyUI `loading` class | `grep -rn '"loading"' packages/nextjs/app/` on button className = FAIL |
| 23 | manifest.json updated | Read public/manifest.json — not "Scaffold-ETH 2 DApp" |

### File Issues
```bash
gh label create "frontend-audit" --repo clawdbotatg/leftclaw-service-job-<ID> --color "f9d0c4" --force
# For each FAIL:
gh issue create --repo clawdbotatg/leftclaw-service-job-<ID> \
  --title "[FAIL] <item>" --body "..." --label "job-<ID>,frontend-audit"
```

**Deliverable:** Checklist with PASS/FAIL for every item. GitHub issues for all FAILs.

**Stop condition:** Do NOT fix anything.

---

## Stage 9 — Frontend QA Fixes

**What you do:** Fix every FAIL from Stage 8. Rebuild.

### 9.1 Fix Each Issue
Read each open issue. Fix the code. Close the issue with commit reference.

### 9.2 Rebuild
```bash
yarn next:build
```

### 9.3 Verify
- [ ] `yarn next:build` exits 0
- [ ] ALL ship-blocker items now PASS
- [ ] ALL should-fix items now PASS

**Deliverable:** All previously-failed items fixed, build passing.

**Stop condition:** Do NOT upload to IPFS.

---

## Stage 10 — Full Audit

**What you do:** One final pass on everything — contracts AND frontend together.

### 10.1 Safety Check
- [ ] Users can always withdraw (no lockups, no admin freeze)
- [ ] Owner cannot steal user deposits
- [ ] Reentrancy guards on all entry points
- [ ] SafeERC20 used throughout
- [ ] TWAP/slippage protection on all swaps
- [ ] All privileged roles set to client address

### 10.2 Frontend-Contract Integration Check
- [ ] Frontend passes correct args to every contract function (check ABI match)
- [ ] Slippage parameters are non-zero
- [ ] All contract addresses in frontend match deployed addresses
- [ ] External contracts registered correctly

### 10.3 Build Check
```bash
cd packages/foundry && forge build      # contracts still compile
yarn next:build                          # frontend still builds
```

### File Issues
```bash
gh label create "full-audit" --repo clawdbotatg/leftclaw-service-job-<ID> --color "5319e7" --force
```

**Deliverable:** Final audit report. Issues filed for any new findings.

**Stop condition:** Do NOT fix anything.

---

## Stage 11 — Full Audit Fixes

Fix any findings from Stage 10. Rebuild both contracts (if changed) and frontend.

---

## Stage 12 — Deploy to IPFS

**What you do:** Build, upload, verify live.

### 12.1 Rebuild Frontend
```bash
# Set production URL for OG metadata
export NEXT_PUBLIC_PRODUCTION_URL="https://placeholder.ipfs.community.bgipfs.com"
yarn next:build
```

### 12.2 Initialize bgipfs
```bash
source .env
npx bgipfs init --token $BGIPFS_TOKEN --endpoint https://upload.bgipfs.com
```

The `--endpoint` flag is MANDATORY. Without it, a bad config is created pointing to localhost. If `ipfs-upload.config.json` exists and points to localhost, delete it and re-run init.

### 12.3 Upload
```bash
npx bgipfs upload packages/nextjs/out
```

Record the CID from the output.

### 12.4 Construct and Verify Live URL
```bash
LIVE_URL="https://<CID>.ipfs.community.bgipfs.com/"
curl -s -o /dev/null -w "%{http_code}" "$LIVE_URL"   # must return 200
```

### 12.5 Verify CID Changed
If you've deployed before, compare CIDs. A code change ALWAYS produces a new CID. Same CID = stale build.

### 12.6 Fix OG Metadata (Chicken-and-Egg)
After first deploy, you know the CID. Rebuild with the real URL:
```bash
export NEXT_PUBLIC_PRODUCTION_URL="https://<CID>.ipfs.community.bgipfs.com"
yarn next:build
npx bgipfs upload packages/nextjs/out
```

The CID will change (new build output). The OG image URL in the new build points to the old CID, which still works on IPFS (content-addressed = permanent).

### 12.7 Verify Live App
```bash
# HTML renders (not blank)
curl -s "$LIVE_URL" | head -20

# Title is correct
curl -s "$LIVE_URL" | grep -i "<title>"

# OG metadata points to absolute URL (not localhost)
curl -s "$LIVE_URL" | grep -i "og:image"
```

**Deliverable:** CID, full live URL, HTTP 200 confirmed.

---

## Stage 13 — Live Fixes

If the live app has issues (broken routes, missing assets, wrong metadata), fix the code, rebuild, and re-upload. Verify the CID changed.

---

## Stage 14 — README + Handoff

**What you do:** Ensure the README is complete for the client.

### README Must Include
- What the project is (1-2 sentences)
- Contract addresses on Base with Basescan links
- How to run locally (`yarn chain`, `yarn deploy`, `yarn start`)
- Architecture (which contract does what)
- Client actions needed:
  - Call `acceptOwnership()` on each contract
  - Set up a keeper for harvest (if applicable)
  - Set `NEXT_PUBLIC_PRODUCTION_URL` if redeploying frontend

### README Must NOT Include
- SE2 template content
- Explanations of what React or Solidity is
- Padding or filler

---

## Stage 15 — Delivery

Report the final result:
- Live URL: `https://<CID>.ipfs.community.bgipfs.com/`
- GitHub repo: `https://github.com/clawdbotatg/leftclaw-service-job-<ID>`
- Contract addresses with Basescan links
- Verification status (all verified)
- Client actions needed (acceptOwnership)

---

## Appendix A — SE2 Footguns

These are specific to Scaffold-ETH 2 and will bite you if you don't know about them.

| Footgun | Fix |
|---------|-----|
| Pre-existing TS error in `useScaffoldEventHistory.ts:132` | `(deployedContractData as any).deployedOnBlock` |
| Font loading — `<link>` tag for Google Fonts | Use `next/font/google` in layout.tsx |
| `polyfill-localstorage.cjs` in wrong directory | Must be in `packages/nextjs/`, not project root |
| Build output in wrong directory | Upload `packages/nextjs/out/`, not `out/` at root |
| Block explorer crashes static export | Rename to `_blockexplorer-disabled` or delete |
| `deployedContracts.ts` manually edited | Never edit — it's auto-generated by `yarn deploy` |
| Default `pollingInterval: 30000` | Change to 3000 in scaffold.config.ts |
| `--radius-field: 9999rem` | Change to 0.5rem in both theme blocks |
| `appName: "scaffold-eth-2"` in wagmiConnectors | Change to your app name |
| `nativeCurrencyPrice` in Footer | Remove — renders ETH price badge on all networks |
| `bgipfs init` without `--endpoint` flag | Creates bad config pointing to localhost |
| Using `useWriteContract` instead of `useScaffoldWriteContract` | Scaffold hooks wait for block confirmation; raw wagmi doesn't |

## Appendix B — Verification Commands

Quick verification commands for common checks:

```bash
# SE2 branding still present?
grep -rn "scaffold-eth-2\|Scaffold-ETH 2\|BuidlGuidl\|scaffold_eth" packages/nextjs/

# Dark backgrounds hardcoded?
grep -rn 'bg-\[#0\|bg-black\|bg-gray-9\|bg-zinc-9' packages/nextjs/app/

# Raw address inputs?
grep -rn 'type="text"' packages/nextjs/app/ | grep -i "addr\|0x"

# Missing error handling?
grep -rn "console.error\|console.log" packages/nextjs/app/ | grep -v node_modules

# Loading class on buttons?
grep -rn '"loading"' packages/nextjs/app/

# Raw wagmi instead of scaffold hooks?
grep -rn "useWriteContract\|useReadContract" packages/nextjs/ | grep -v scaffold-eth | grep -v node_modules

# OG image still localhost?
grep -rn "localhost" packages/nextjs/utils/ packages/nextjs/app/layout.tsx

# Public RPC in foundry config?
grep -n "mainnet.base.org\|base.llamarpc" packages/foundry/foundry.toml
```

## Appendix C — The Three-Phase Model

From the ethskills orchestration guide, development follows three phases:

### Phase 1 — Local (Contracts + UI on localhost)
- Fork the target chain: `yarn fork --network base`
- Deploy contracts to the fork: `yarn deploy`
- Build and test UI against forked state: `yarn start`
- All protocols available (Uniswap, tokens, whale balances)
- Chain ID = 31337 (foundry), not the real chain
- Enable block mining: `cast rpc anvil_setIntervalMining 1`

### Phase 2 — Live Contracts + Local UI
- Deploy contracts to real chain (Base)
- Verify on block explorer
- Run frontend locally against live contracts
- Test with real wallet, small amounts
- This is where integration bugs surface

### Phase 3 — Production
- Deploy frontend to IPFS (bgipfs)
- Full QA testing on live app
- Verify OG metadata, routes, mobile flows
- This is where deployment bugs surface

**Regression rule:** Production bugs → go back to Phase 2. Contract bugs → go back to Phase 1.

## Appendix D — Common Mistakes From Real Builds

These are not theoretical — they happened on actual builds.

| Mistake | Job | Impact |
|---------|-----|--------|
| Subagent reported "all SE2 branding removed" but didn't actually change the files | #46 | Wasted a full audit+fix cycle (15 out of 21 QA items still failing) |
| Approve button re-enabled between wallet hash return and on-chain confirmation | #43 | Users could double-approve, wasting gas |
| TWAP oracle check ran AFTER the swap instead of before | #46 | Sandwich attack protection was completely ineffective |
| `minWstETHOut: 0n` passed in frontend deposit call | #46 | Zero slippage protection despite contract having the parameter |
| Withdraw principal tracking subtracted raw assets instead of proportional | #46 | Share accounting would drift over time |
| OG image pointed to `localhost:3000` | #43, #46 | Social sharing/unfurling completely broken |
| Deploy script transferred ownership before configuring cross-references | #46 | Post-deploy config race — nobody could call admin functions |
| `pool.observe()` called without try/catch | #46 | Would revert on new pools with insufficient observation history |

## Appendix E — Post-Build Verification Checklist

Run this after EVERY subagent build stage to verify claims before proceeding:

```bash
# After contract build:
cd packages/foundry && forge build && echo "CONTRACTS: PASS" || echo "CONTRACTS: FAIL"

# After frontend build:
yarn next:build && echo "FRONTEND: PASS" || echo "FRONTEND: FAIL"

# After SE2 cleanup claims:
echo "=== SE2 BRANDING CHECK ==="
grep -c "scaffold-eth-2" packages/nextjs/services/web3/wagmiConnectors.tsx && echo "appName: FAIL" || echo "appName: PASS"
grep -c "Scaffold-ETH 2" packages/nextjs/utils/scaffold-eth/getMetadata.ts && echo "title: FAIL" || echo "title: PASS"
grep -c "BuidlGuidl" packages/nextjs/components/Footer.tsx && echo "footer: FAIL" || echo "footer: PASS"
grep -c "9999rem" packages/nextjs/styles/globals.css && echo "radius: FAIL" || echo "radius: PASS"
ls packages/nextjs/app/blockexplorer 2>/dev/null && echo "blockexplorer: FAIL" || echo "blockexplorer: PASS"

# After approval flow claims:
echo "=== APPROVAL FLOW CHECK ==="
grep -c "approvalSubmitting" packages/nextjs/app/page.tsx && echo "approvalSubmitting: PRESENT" || echo "approvalSubmitting: MISSING"
grep -c "approvalCooldown" packages/nextjs/app/page.tsx && echo "approvalCooldown: PRESENT" || echo "approvalCooldown: MISSING"
grep -c "finally" packages/nextjs/app/page.tsx && echo "finally block: PRESENT" || echo "finally block: MISSING"
```

Never trust "all done" from a subagent. Verify before advancing to the next stage.
