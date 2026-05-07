# COMPREHENSIVE dApp BUILD PLAYBOOK

> The definitive guide for AI agents building decentralized applications on Scaffold-ETH 2.
> Synthesized from 6 production playbooks, 8 ethskills skill files, SE2 AGENTS.md, and lessons from real builds (Jobs #43, #46).

---

## PHILOSOPHY

AI is sloppy. It hallucinates. It says "done" when it isn't. It skips tests. It doesn't double-check.

This playbook enforces one pattern at every stage:

```
DO THE THING → VERIFY THE THING WORKS → VERIFY IT DOES WHAT IT'S SUPPOSED TO → FIX REPEATEDLY UNTIL SOLID → CONTINUE
```

No stage advances until its exit criteria are met. No claims without evidence. No "it should work" — only "here's the proof it works."

---

## TABLE OF CONTENTS

- [Phase 0: Architecture & Spec](#phase-0-architecture--spec)
- [Phase 1: Discovery](#phase-1-discovery)
- [Phase 2: Scaffold + Repo](#phase-2-scaffold--repo)
- [Phase 3: Write Contracts](#phase-3-write-contracts)
- [Phase 4: Contract Verification Gate](#phase-4-contract-verification-gate)
- [Phase 5: Contract Audit](#phase-5-contract-audit)
- [Phase 6: Contract Fixes](#phase-6-contract-fixes)
- [Phase 7: Deploy + Verify](#phase-7-deploy--verify)
- [Phase 8: External Contracts Setup](#phase-8-external-contracts-setup)
- [Phase 9: Frontend Build](#phase-9-frontend-build)
- [Phase 10: Frontend QA Audit](#phase-10-frontend-qa-audit)
- [Phase 11: Frontend QA Fixes](#phase-11-frontend-qa-fixes)
- [Phase 12: IPFS Deploy](#phase-12-ipfs-deploy)
- [Phase 13: Live User Journey](#phase-13-live-user-journey)
- [Phase 14: README + Metadata](#phase-14-readme--metadata)
- [Phase 15: Delivery](#phase-15-delivery)
- [Appendix A: SE2 Footguns](#appendix-a-se2-footguns)
- [Appendix B: SE2 Branding Cleanup Checklist](#appendix-b-se2-branding-cleanup-checklist)
- [Appendix C: QA Audit Checklist (Full)](#appendix-c-qa-audit-checklist-full)
- [Appendix D: Security Patterns](#appendix-d-security-patterns)
- [Appendix E: Command Reference](#appendix-e-command-reference)
- [Appendix F: File Inventory](#appendix-f-file-inventory)
- [Appendix G: Error Patterns + Auto-Fix Strategies](#appendix-g-error-patterns--auto-fix-strategies)
- [Appendix H: Model Routing](#appendix-h-model-routing)
- [Appendix I: Cost Model](#appendix-i-cost-model)

---

## CORE RULES (apply to every stage)

### Orchestrator Discipline
The orchestrator runs NO build commands, reads NO code files, does NO debugging. All implementation is delegated to subagents. If you're running `yarn`, `forge`, or `grep` on source code — stop. That's the subagent's job.

### One Stage Per Invocation
Each subagent does ONE stage. Never combine stages. Small + isolated = measurable + testable. A stage either passes or it doesn't — you know exactly what broke and where.

### Verify Subagent Claims
**Never trust a subagent's claim that work is complete.** Run verification commands yourself after the subagent returns. On Job #46, a frontend subagent claimed all SE2 cleanup was done — the audit found 15 of 21 items still FAILING. The changes were never applied despite the agent claiming "all done."

### Secrets
- NEVER use the `Read` tool on `.env` — the private key appears in conversation
- To get worker address: `cast wallet address --private-key $PRIVATE_KEY`
- To check a value: `grep KEY_NAME .env | cut -d= -f2`
- NEVER commit `.env`, API keys, or private keys
- NEVER hardcode RPC URLs with embedded keys in config files

### RPC
Always use Alchemy endpoints with API key from `.env`. NEVER use public RPCs (`mainnet.base.org`, `base.llamarpc.com`, `eth.llamarpc.com`). Not in scripts. Not in ad-hoc shell commands. Not anywhere.

### Git
All repos go to the configured git user. Verify with `gh auth status` before every push.

### Skill Files Are Source of Truth
Read the skill files. Every time. Your training data is not the source of truth. A previous instance described the build pipeline as 5 steps instead of 23, named the wrong deploy command, and skipped all audit stages — because it answered from training knowledge.

---

## PHASE 0: ARCHITECTURE & SPEC

**Purpose:** Turn a job description into a precise, testable specification before writing any code. This is where 80% of build failures are prevented.

**Subagent prompt prefix:** "Read ~/clawd/ethereum-servicer/CLAUDE.md (Known Build Footguns section) before starting."

### 0.1 — Parse the Spec

Extract from the job description + all client messages:

| Field | Example |
|-------|---------|
| `appName` | "ClawdETH" |
| `appDescription` | "ETH Liquid Staking with CLAWD Yield Redirection" |
| `targetChain` | Base (8453) |
| `archetype` | vault / token-launch / NFT / marketplace / DAO / agent / dashboard |
| `contracts` | list of contract names + purposes |
| `externalDependencies` | wstETH, Uniswap V3, CLAWD token — addresses for target chain |
| `clientWallet` | the address that will own everything |
| `uiRequirements` | any specific design/UX requirements from client messages |

### 0.2 — Onchain Litmus Test

For each piece of functionality, ask: **Does this NEED to be onchain?**

Put it onchain ONLY if it requires:
- Trustless ownership or exchange
- Composability with other protocols
- Censorship resistance
- Permissionless access

Everything else goes in the frontend or off-chain.

### 0.3 — State Transition Audit

For every contract function:
- **Who** calls it? (user, owner, keeper, anyone)
- **Why** do they call it? (what incentive?)
- **What if nobody calls it?** (does the system break?)
- **What's the worst thing that happens if it's called with malicious inputs?**

### 0.4 — Hyperstructure Test

Could this run forever with no team maintaining it? If not, document exactly what breaks without maintenance and who is responsible.

### 0.5 — Chain Selection (if not specified)

| Chain | Gas Cost | Finality | Best For |
|-------|----------|----------|----------|
| Base | ~$0.001 | ~2s | General dApps, social, DeFi |
| Arbitrum | ~$0.01 | ~250ms | DeFi, high-frequency |
| Mainnet | ~$1-50 | ~12s | High-value, settlement |
| Optimism | ~$0.001 | ~2s | Public goods, governance |

### 0.6 — Write SPEC_REQUIREMENTS.md

Convert the spec into numbered, testable requirements:

```markdown
# SPEC_REQUIREMENTS.md

## Contracts
R1: ClawdETHVault MUST be ERC4626-compliant with wstETH as underlying asset
R2: Deposits MUST accept ETH, wrap to wstETH internally
R3: Yield MUST be calculated as wstETH balance growth above total principal
...

## Frontend
R20: User MUST be able to deposit ETH and receive clawdETH shares
R21: User MUST see their current position value in USD
...
```

Every requirement gets verified at the end. If it can't be tested, rewrite it until it can.

### EXIT CRITERIA
- [ ] `SPEC_REQUIREMENTS.md` exists with numbered requirements
- [ ] Every external address verified with `cast call` on target chain
- [ ] Archetype identified, chain selected
- [ ] State transition audit complete for every function
- [ ] Client messages read — no hidden requirements missed

---

## PHASE 1: DISCOVERY

**Purpose:** Discover real interfaces, ABIs, and package exports BEFORE writing code. Prevents hallucinated imports and wrong function signatures.

### 1.1 — External Contract Discovery

For every external contract the dApp interacts with:

```bash
# Get the REAL ABI from on-chain bytecode
cast interface <address> --rpc-url $ALCHEMY_RPC_URL

# Verify the contract is what you think it is
cast call <address> "name()(string)" --rpc-url $ALCHEMY_RPC_URL
cast call <address> "symbol()(string)" --rpc-url $ALCHEMY_RPC_URL
cast call <address> "decimals()(uint8)" --rpc-url $ALCHEMY_RPC_URL
```

**Why this matters:** On Job #46, `wstETH` on Base has a different interface than mainnet. `cast interface` returns the REAL function signatures, not what your training data says.

### 1.2 — Package Export Discovery

Before importing from any npm package, check what it actually exports:

```bash
# Check what's actually exported
node -e "const m = require('@uniswap/v3-periphery/artifacts/...'); console.log(Object.keys(m))"

# Or for ES modules
grep -r "export" node_modules/<package>/dist/index.d.ts | head -20
```

### 1.3 — Verified Address Table

Create a reference table of every external address you'll use:

| Contract | Address | Chain | Verified |
|----------|---------|-------|----------|
| wstETH | 0x... | Base | cast call name() = "Wrapped liquid staked Ether 2.0" |
| USDC | 0x... | Base | cast call decimals() = 6 |
| SwapRouter02 | 0x... | Base | cast call factory() = 0x... |

### EXIT CRITERIA
- [ ] Every external contract ABI retrieved via `cast interface`
- [ ] Every address verified with at least one `cast call`
- [ ] Verified address table complete
- [ ] Token decimals confirmed (not assumed)
- [ ] Package exports confirmed for all dependencies

---

## PHASE 2: SCAFFOLD + REPO

**Purpose:** Create the SE2 scaffold and GitHub repo. Scaffold first, then repo. Never the other way around.

### 2.1 — Check for Existing Build

```bash
ls ~/clawd/ethereum-servicer/builds/leftclaw-service-job-JOBID 2>/dev/null
```

If it exists, inspect state (git log, contracts, deployedContracts.ts) before scaffolding fresh. Reusing a valid prior build saves a full cycle.

### 2.2 — Scaffold

```bash
npx create-eth@latest leftclaw-service-job-JOBID \
  --extension none \
  --solidity-framework foundry \
  --skip-install false
```

Flags: `--extension none` (no extensions), `--solidity-framework foundry` (always Foundry), `--skip-install false` (install deps).

### 2.3 — Create GitHub Repo

```bash
cd ~/clawd/ethereum-servicer/builds/leftclaw-service-job-JOBID
git init
gh repo create clawdbotatg/leftclaw-service-job-JOBID --public --source=. --push
```

### 2.4 — Verify Scaffold

```bash
cd packages/foundry && forge build
cd ../nextjs && yarn build
```

Both must exit 0 before proceeding.

### EXIT CRITERIA
- [ ] Directory exists at expected path
- [ ] GitHub repo created and accessible
- [ ] `forge build` exits 0
- [ ] `yarn build` exits 0 (on clean scaffold)
- [ ] Git remote points to correct user/repo

---

## PHASE 3: WRITE CONTRACTS

**Purpose:** Write Solidity contracts that compile cleanly. NO deploy. NO frontend.

### 3.1 — Contract Architecture

Follow these patterns:
- **Ownable2Step** over Ownable (prevents accidental ownership transfer)
- **SafeERC20** for all token interactions
- **ReentrancyGuard** on all external-facing state-changing functions
- **CEI pattern** (Checks-Effects-Interactions) — always
- **ERC4626:** Override `_deposit` and `_withdraw` internal hooks, NOT public functions
- **Virtual shares** for ERC4626 (prevents inflation attack): override `_decimalsOffset()` to return 6+

### 3.2 — Deploy Script

Write the deploy script but DO NOT run it yet.

**Deployer-first pattern:** Deploy as initial owner → configure cross-references between contracts → transfer ownership to client LAST.

```solidity
// CORRECT order:
// 1. Deploy all contracts (deployer is initial owner)
// 2. Configure cross-references (vault.setHarvester(), rewards.setDistributor())
// 3. Transfer ownership to client (vault.transferOwnership(client))
```

### 3.3 — Compile

```bash
cd packages/foundry && forge build
```

Must exit 0 with no warnings.

### 3.4 — Write Tests (optional but recommended for complex contracts)

```bash
forge test
forge test --fuzz-runs 1000  # for math-heavy contracts
```

### EXIT CRITERIA
- [ ] All contracts in `packages/foundry/contracts/`
- [ ] Deploy script in `packages/foundry/script/`
- [ ] `forge build` exits 0, no warnings
- [ ] Tests pass (if written)
- [ ] No deployment attempted
- [ ] No frontend code written
- [ ] Committed and pushed

---

## PHASE 4: CONTRACT VERIFICATION GATE

**Purpose:** Verify contracts implement the SPEC, not just that they compile. Compilation proves syntax; this proves semantics.

### 4.1 — Spec Requirement Mapping

For each requirement in `SPEC_REQUIREMENTS.md`:

| Req | Contract | Function | Verified How |
|-----|----------|----------|-------------|
| R1 | ClawdETHVault | asset() | Returns wstETH address |
| R2 | ClawdETHVault | deposit() | Accepts ETH via receive(), wraps to wstETH |
| R3 | ClawdETHVault | _yieldAmount() | Returns balance - totalPrincipal |

### 4.2 — DeFi-Specific Checks

If the contract involves DeFi:
- [ ] Underlying asset address correct for target chain (not mainnet address on L2)
- [ ] Yield mechanism is real (not a stub or placeholder)
- [ ] Swap path exists on target chain (check pool liquidity)
- [ ] Token decimals handled correctly (6 for USDC, 18 for most ERC20s)
- [ ] Slippage protection present (not `amountOutMinimum: 0`)
- [ ] Oracle/TWAP checks happen BEFORE swaps, not after

### 4.3 — Cross-Reference Check

If multiple contracts interact:
- [ ] Each contract can reference the others (setter functions exist)
- [ ] Access control allows the expected callers
- [ ] No circular initialization dependencies

### EXIT CRITERIA
- [ ] Every SPEC_REQUIREMENTS.md item mapped to specific contract code
- [ ] No stub implementations ("TODO", empty functions, hardcoded returns)
- [ ] DeFi-specific checks pass
- [ ] Cross-reference pattern documented

---

## PHASE 5: CONTRACT AUDIT

**Purpose:** Security audit of contract source code. Read-only — do NOT fix anything.

### 5.1 — Fetch Audit Skill

```
https://ethskills.com/audit/SKILL.md
```

This launches 20 parallel specialist sub-agents covering: general EVM, precision math, ERC20, ERC721, ERC1155, ERC4626, AMM/DEX, lending, staking, flash loans, proxies, bridges, oracles, account abstraction, signatures, governance, assembly, DoS, access control, chain-specific.

### 5.2 — Run the Audit

Spawn parallel specialist agents against the contract source. Each specialist uses its domain-specific checklist from:
```
https://raw.githubusercontent.com/austintgriffith/evm-audit-skills/main/<skill-name>/references/checklist.md
```

### 5.3 — Consolidated Report

Every finding must include:
- **Severity:** Critical / High / Medium / Low / Info
- **Location:** file:line
- **Description:** what's wrong
- **Recommendation:** how to fix

### 5.4 — File GitHub Issues

For every Medium+ finding, file a GitHub issue:

```bash
gh issue create --title "[SEVERITY] Finding title" --body "..." --repo clawdbotatg/leftclaw-service-job-JOBID
```

### EXIT CRITERIA
- [ ] All 20 audit domains run (or relevant subset for simple contracts)
- [ ] Consolidated report with every finding enumerated
- [ ] GitHub issues filed for Medium+ findings
- [ ] NO files modified — audit is read-only

---

## PHASE 6: CONTRACT FIXES

**Purpose:** Fix every Critical/High finding. Address Medium findings. Low/Info at discretion.

### 6.1 — Fix Priority

1. **Critical:** Must fix. No exceptions.
2. **High:** Must fix. No exceptions.
3. **Medium:** Fix unless there's a documented technical reason not to.
4. **Low/Info:** Fix if trivial, otherwise document "won't fix" with reason.

### 6.2 — Verify Fix Loop

For each finding:
1. Apply fix
2. Run `forge build` — must pass
3. Run `forge test` — must pass (if tests exist)
4. Verify the fix actually addresses the finding (not just suppresses the symptom)

**Rule: Fix the test, not the contract.** If a test fails after a legitimate security fix, the test was wrong. Update the test to match the correct behavior.

### 6.3 — Itemized Response

For every finding from Phase 5:
- **Fixed:** link to commit
- **Won't fix:** reason (must be a real technical reason, not laziness)

### EXIT CRITERIA
- [ ] Zero Critical findings remain
- [ ] Zero High findings remain
- [ ] Every Medium finding addressed or documented
- [ ] `forge build` exits 0
- [ ] `forge test` passes (if tests exist)
- [ ] Close GitHub issues for fixed findings
- [ ] Committed and pushed

---

## PHASE 7: DEPLOY + VERIFY

**Purpose:** Deploy contracts to the target chain and verify on block explorer.

### 7.1 — Pre-Deploy Checks

```bash
# Verify deployer has funds
cast balance $(cast wallet address --private-key $PRIVATE_KEY) --rpc-url $ALCHEMY_RPC_URL

# Verify target chain config
grep -A5 "base" packages/foundry/foundry.toml
```

### 7.2 — Deploy

```bash
yarn deploy --network base
```

### 7.3 — Verify on Block Explorer

```bash
yarn verify --network base
```

No Basescan API key needed — this is SE2 built-in. Don't claim otherwise.

### 7.4 — Confirm Verification

For each deployed contract, check that the block explorer shows:
- Green checkmark on "Contract" tab
- Source code readable
- ABI available

```bash
# Check deployedContracts.ts was updated
grep -l "8453" packages/nextjs/contracts/deployedContracts.ts
```

### 7.5 — Ownership Transfer

If using deployer-first pattern, ownership should have been transferred in the deploy script. Verify:

```bash
cast call <contract_address> "owner()(address)" --rpc-url $ALCHEMY_RPC_URL
# Must return client wallet, NOT deployer
```

### EXIT CRITERIA
- [ ] All contracts deployed to target chain
- [ ] `deployedContracts.ts` auto-generated with correct chain ID
- [ ] All contracts verified on block explorer (green checkmark)
- [ ] Ownership transferred to client wallet (verified with `cast call`)
- [ ] Committed and pushed

---

## PHASE 8: EXTERNAL CONTRACTS SETUP

**Purpose:** Register all external contracts in `externalContracts.ts` so SE2 hooks work with them.

### 8.1 — Identify External Contracts

Any contract NOT deployed by this project but used in the frontend:
- Token contracts (USDC, WETH, wstETH, etc.)
- Protocol contracts (Uniswap Router, Aave Pool, etc.)
- Any contract the UI needs to read from or write to

### 8.2 — Write externalContracts.ts

```typescript
// packages/nextjs/contracts/externalContracts.ts
export default {
  8453: {  // Base chain ID
    wstETH: {
      address: "0x...",
      abi: [...],  // Use ABI from cast interface or verified source
    },
  },
} as const;
```

### 8.3 — Verify Registration

```bash
# All external contracts referenced in components must be in externalContracts.ts
grep -rn "contractName:" packages/nextjs/app/ packages/nextjs/components/ | \
  grep -v node_modules | sort -u
```

Every `contractName` must appear in either `deployedContracts.ts` or `externalContracts.ts`.

### EXIT CRITERIA
- [ ] All external contracts registered with correct chain, address, and ABI
- [ ] `deployedContracts.ts` NOT manually edited
- [ ] Every contractName used in hooks has a matching registration
- [ ] Committed and pushed

---

## PHASE 9: FRONTEND BUILD

**Purpose:** Implement the UI. Use SE2 hooks exclusively. Run `yarn build` (static export). NO IPFS upload yet.

### 9.1 — Read the Skill Files

Before writing any frontend code, read:
- `https://ethskills.com/frontend-playbook/SKILL.md`
- `https://ethskills.com/frontend-ux/SKILL.md`
- `https://ethskills.com/qa/SKILL.md`
- SE2 AGENTS.md (hook names, components, styling)

### 9.2 — SE2 Hook Rules

**USE SCAFFOLD HOOKS, NOT RAW WAGMI.**

| Do This | Not This |
|---------|----------|
| `useScaffoldReadContract` | ~~useContractRead~~ / ~~useScaffoldContractRead~~ |
| `useScaffoldWriteContract` | ~~useWriteContract~~ / ~~useScaffoldContractWrite~~ |
| `useScaffoldEventHistory` | ~~useContractEvent~~ |

```bash
# Verify no raw wagmi in app code (outside scaffold internals)
grep -rn "useWriteContract\|useReadContract\|useContractRead\|useContractWrite" packages/nextjs/app/ packages/nextjs/components/
```

Any match outside scaffold-eth internals = bug.

### 9.3 — Component Rules

| Display | Component |
|---------|-----------|
| Ethereum address (display) | `<Address address={addr} />` |
| Ethereum address (input) | `<AddressInput value={addr} onChange={setAddr} />` |
| ETH balance | `<Balance address={addr} />` |
| ETH amount input | `<EtherInput value={val} onChange={setVal} />` |
| Integer input | `<IntegerInput value={val} onChange={setVal} />` |

Import from `~~/components/scaffold-eth` or `@scaffold-ui/components`.

### 9.4 — Four-State Button Flow

Every page that writes to a contract must implement:

```
1. Not connected  → <RainbowKitCustomConnectButton />  (BUTTON, not text)
2. Wrong network  → Switch to Base button
3. Needs approval → Approve button (with two-state protection)
4. Ready          → Action button
```

**ONE button at a time. Never show Approve + Action simultaneously.**

### 9.5 — Two-State Approval Protection

```tsx
const [approvalSubmitting, setApprovalSubmitting] = useState(false);
const [approveCooldown, setApproveCooldown] = useState(false);

const handleApprove = async () => {
  if (approvalSubmitting || approveCooldown) return;
  setApprovalSubmitting(true);
  try {
    await approveWrite({ functionName: "approve", args: [spender, amount] });
    setApproveCooldown(true);
    setTimeout(() => { setApproveCooldown(false); refetchAllowance(); }, 4000);
  } catch (e) { notifyError("Approval failed"); }
  finally { setApprovalSubmitting(false); }
};

<button disabled={isPending || approvalSubmitting || approveCooldown}>
```

### 9.6 — Mobile Deep Linking

RainbowKit v2 / WalletConnect v2 does NOT auto-deep-link. Implement the `writeAndOpen` pattern:

```typescript
const writeAndOpen = useCallback(
  <T,>(writeFn: () => Promise<T>): Promise<T> => {
    const promise = writeFn();
    setTimeout(openWallet, 2000);  // 2s delay for WC relay
    return promise;
  },
  [openWallet],
);
```

Fire TX first, deep link second. Never `window.location.href` before `writeContractAsync`. Skip deep link if `window.ethereum` exists (in-app browser).

### 9.7 — Error Handling

Map contract errors to human-readable messages. Never display raw revert hex selectors. Use `getParsedError` from `~~/utils/scaffold-eth`.

### 9.8 — Styling Rules

- Use **DaisyUI classes**, not raw Tailwind for components that have DaisyUI equivalents
- Use **semantic theme tokens**: `bg-base-100`, `bg-base-200`, `text-base-content` — never hardcode `bg-[#0a0a0a]` or `bg-black`
- Button loaders: `<span className="loading loading-spinner loading-sm" />` INSIDE the button. Never `className="... loading"` ON the button
- `--radius-field: 0.5rem` in both theme blocks in `globals.css` (not `9999rem`)

### 9.9 — SE2 Branding Cleanup

Do this DURING frontend build, not as an afterthought. See [Appendix B](#appendix-b-se2-branding-cleanup-checklist) for full checklist.

### 9.10 — Disable Block Explorer for IPFS

```bash
mv packages/nextjs/app/blockexplorer packages/nextjs/app/_blockexplorer-disabled
```

The block explorer uses `localStorage` at import time and crashes static export.

### 9.11 — Build

```bash
cd packages/nextjs
rm -rf .next out

NODE_OPTIONS="--require ./polyfill-localstorage.cjs" \
  NEXT_PUBLIC_IPFS_BUILD=true \
  NEXT_PUBLIC_IGNORE_BUILD_ERROR=true \
  yarn build
```

**polyfill-localstorage.cjs** must be in `packages/nextjs/`, NOT the project root. Node 25+ ships with a broken `localStorage` object missing WebStorage API methods. Create the polyfill:

```javascript
if (typeof globalThis.localStorage !== "undefined" &&
    typeof globalThis.localStorage.getItem !== "function") {
  const store = new Map();
  globalThis.localStorage = {
    getItem: (key) => store.get(key) ?? null,
    setItem: (key, value) => store.set(key, String(value)),
    removeItem: (key) => store.delete(key),
    clear: () => store.clear(),
    key: (index) => [...store.keys()][index] ?? null,
    get length() { return store.size; },
  };
}
```

### EXIT CRITERIA
- [ ] `yarn build` exits 0
- [ ] `packages/nextjs/out/` directory exists
- [ ] No raw wagmi hooks in app code
- [ ] Four-state button flow implemented
- [ ] Two-state approval protection implemented
- [ ] Mobile deep linking implemented
- [ ] SE2 branding removed (full checklist)
- [ ] Block explorer disabled
- [ ] polyfill-localstorage.cjs in correct location
- [ ] Contract errors mapped to human-readable messages
- [ ] DaisyUI semantic theming (no hardcoded dark)
- [ ] Committed and pushed

---

## PHASE 10: FRONTEND QA AUDIT

**Purpose:** Fresh-eye audit of the frontend. Read-only. DO NOT fix anything.

### 10.1 — Fetch QA Skill

```
https://ethskills.com/qa/SKILL.md
```

### 10.2 — Spawn Fresh QA Agent

Give a FRESH agent (no prior context) the source code and the full checklist from [Appendix C](#appendix-c-qa-audit-checklist-full). The reviewer:
1. Reads all source code (`app/`, `components/`, `contracts/`, `scaffold.config.ts`, `globals.css`)
2. Reports PASS/FAIL for every checklist item
3. Does NOT fix anything

### 10.3 — Ship-Blockers vs. Should-Fix

**Ship-blockers** (must ALL pass before IPFS deploy):
- Wallet connect shows a BUTTON, not text
- Wrong network shows Switch button
- One button at a time (Connect → Network → Approve → Action)
- Approve button locked through full cycle (both states)
- Contracts verified on block explorer
- SE2 footer branding removed (including `nativeCurrencyPrice` badge in Footer.tsx)
- SE2 tab title removed (`"%s | Scaffold-ETH 2"` → `"%s"`)
- SE2 README replaced
- Favicon replaced

**Should-fix** (must pass before delivery):
- Contract address displayed with `<Address/>`
- Every address input uses `<AddressInput/>`
- OG image uses absolute URL
- `pollingInterval: 3000`
- RPC overrides set
- `--radius-field: 0.5rem`
- USD context for token amounts
- Errors mapped to human-readable messages
- Phantom wallet in RainbowKit
- Mobile deep linking (writeAndOpen pattern)
- `appName` changed from `"scaffold-eth-2"` in `wagmiConnectors.tsx`
- No hardcoded dark backgrounds
- Button loaders use inline spinner, not className

### EXIT CRITERIA
- [ ] Full audit report with every item explicitly PASS or FAIL
- [ ] NO files modified — audit is read-only

---

## PHASE 11: FRONTEND QA FIXES

**Purpose:** Fix every FAIL from Phase 10.

### 11.1 — Fix All Ship-Blockers First

Fix every ship-blocker FAIL. Then verify each fix:

```bash
# Example verifications:
grep -rn "Please connect\|Connect your wallet to" packages/nextjs/app/  # Should find NOTHING
grep -rn "BuidlGuidl\|Fork me\|scaffold-eth-2\|Scaffold-ETH 2" packages/nextjs/  # Should find NOTHING (outside node_modules)
grep -rn "loading\"" packages/nextjs/app/  # Check for wrong loading pattern
```

### 11.2 — Fix All Should-Fix Items

### 11.3 — Rebuild

```bash
cd packages/nextjs && rm -rf .next out
NODE_OPTIONS="--require ./polyfill-localstorage.cjs" \
  NEXT_PUBLIC_IPFS_BUILD=true \
  NEXT_PUBLIC_IGNORE_BUILD_ERROR=true \
  yarn build
```

### 11.4 — Verify Every Previously-Failed Item

Re-run the checklist. Every item that was FAIL must now be PASS. Don't take the subagent's word — run the grep commands yourself.

### EXIT CRITERIA
- [ ] All ship-blockers PASS
- [ ] All should-fix items PASS
- [ ] `yarn build` exits 0
- [ ] Verification greps confirm changes were actually applied
- [ ] Committed and pushed

---

## PHASE 12: IPFS DEPLOY

**Purpose:** Deploy frontend to bgipfs. Get a live URL.

### 12.1 — bgipfs Init (first time only)

```bash
npx bgipfs init --token $BGIPFS_TOKEN --endpoint https://upload.bgipfs.com
```

The `--endpoint` flag is MANDATORY. Without it, init creates a bad config pointing to localhost.

### 12.2 — Upload

```bash
npx bgipfs upload packages/nextjs/out
```

Upload `packages/nextjs/out/` — NOT `out/` at root.

### 12.3 — Verify CID Changed

If you've deployed before, the new CID MUST be different from the old one. Same CID = stale build uploaded. **Stop and investigate if CID matches a previous deployment.**

### 12.4 — Verify Live URL

```bash
curl -s -o /dev/null -w "%{http_code}" "https://<CID>.ipfs.community.bgipfs.com/"
# Must return 200
```

### 12.5 — OG Image Chicken-and-Egg

IPFS URLs contain the CID, but OG metadata must reference the production URL. This requires TWO deploys:

1. **First deploy:** Get a CID (OG image may point to wrong URL)
2. **Set `NEXT_PUBLIC_PRODUCTION_URL`** to `https://<CID>.ipfs.community.bgipfs.com`
3. **Rebuild and redeploy:** Now OG image points to correct URL with correct CID

Verify:
```bash
curl -s "https://<NEW_CID>.ipfs.community.bgipfs.com/" | grep 'og:image'
# Must show absolute URL pointing to the CURRENT deployment
```

### EXIT CRITERIA
- [ ] HTTP 200 on live URL
- [ ] CID is different from any previous CID
- [ ] OG image resolves to absolute production URL
- [ ] Full URL format: `https://<CID>.ipfs.community.bgipfs.com/`
- [ ] Never Vercel, Netlify, or any other host

---

## PHASE 13: LIVE USER JOURNEY

**Purpose:** Test the actual deployed dApp end-to-end with a real wallet.

### 13.1 — Full Flow Test

1. Open live URL in browser
2. Verify page loads, no console errors
3. Connect wallet
4. Switch to correct network (if prompted)
5. Execute the primary user journey:
   - For a vault: deposit → check shares → withdraw
   - For an NFT: mint → view → transfer
   - For a marketplace: list → buy → verify ownership
6. Verify all state changes reflect on-chain

### 13.2 — Edge Cases

- Zero amount input
- Amount exceeding balance
- Wallet rejection (user cancels)
- Wrong network behavior
- Multiple rapid clicks
- Mobile viewport

### 13.3 — Trust Signals

- [ ] Contract addresses visible and linked to block explorer
- [ ] Block explorer shows verified source code
- [ ] No SE2 branding visible
- [ ] Project-specific favicon in browser tab
- [ ] Social preview (OG image) renders when URL is shared

### EXIT CRITERIA
- [ ] Full user journey completes successfully
- [ ] Edge cases handled gracefully
- [ ] No console errors
- [ ] Trust signals all present

---

## PHASE 14: README + METADATA

**Purpose:** Replace SE2 template content with project-specific documentation.

### 14.1 — README.md

Replace the SE2 README entirely. Include:
- Project name and description
- What the dApp does (one paragraph)
- Contract addresses on the target chain
- Link to live deployment
- Link to verified contracts on block explorer
- How to run locally (for developers)

### 14.2 — Metadata Files

- `manifest.json` or `site.webmanifest` — project name, not SE2
- OG image — custom 1200x630 PNG (not SE2 default)
- Favicon — project-specific (not SE2 scaffold logo)

### EXIT CRITERIA
- [ ] README describes THIS project, not SE2
- [ ] No SE2 template content remains
- [ ] Committed and pushed

---

## PHASE 15: DELIVERY

**Purpose:** Final delivery to the client.

### 15.1 — Pre-Delivery Checklist

Run through every phase's exit criteria one more time:

- [ ] Contracts deployed and verified
- [ ] Ownership transferred to client
- [ ] Frontend live on IPFS
- [ ] All QA items passing
- [ ] README updated
- [ ] GitHub repo clean (no debug code, no TODO comments, no .env committed)

### 15.2 — Deliver

```bash
npx tsx scripts/work.ts complete <jobId> "https://<CID>.ipfs.community.bgipfs.com/"
```

### 15.3 — Client Notification

Post a message with:
- Live URL
- Contract addresses
- Block explorer links
- GitHub repo URL
- Any known limitations or future improvements

### EXIT CRITERIA
- [ ] Job marked complete
- [ ] Client notified with all deliverables
- [ ] Full URL provided (not raw CID)

---

## APPENDIX A: SE2 FOOTGUNS

These are real bugs that have cost real time on real builds. Read before every stage.

| Footgun | What Goes Wrong | Fix |
|---------|----------------|-----|
| `useScaffoldEventHistory.ts:132` type error | SE2 ships with `deployedOnBlock` resolving to `{}` not assignable to `BigInt` | Type assertion. Don't investigate — it's a scaffold bug |
| Font loading via `<link>` tag | Next.js warns/fails | Use `next/font/google` in `layout.tsx` |
| `bgipfs init` without `--endpoint` | Creates bad config pointing to localhost | Delete `ipfs-upload.config.json`, re-run with `--endpoint https://upload.bgipfs.com` |
| Build output at `out/` (root) | Wrong directory | Upload `packages/nextjs/out/`, not root `out/` |
| Same CID after code changes | Deployed stale build | `rm -rf .next out` before rebuild, verify CID changed |
| `yarn verify` needs API key | FALSE — SE2 built-in verification works without Basescan key | Just run `yarn verify --network base` |
| polyfill in project root | Build still crashes | Must be in `packages/nextjs/` |
| Block explorer in static export | `localStorage` crash at import time, silent 404s | Rename to `_blockexplorer-disabled` |
| `deployedContracts.ts` manually edited | Gets overwritten on next deploy | Use `externalContracts.ts` for external contracts |
| `forge init` instead of `create-eth` | No SE2 frontend, no hooks, no components | Always `npx create-eth@latest` |
| `yarn chain` instead of `yarn fork` | Empty chain, no protocols or tokens | `yarn fork --network base` for real state |
| `chains.base` in dev instead of `chains.foundry` | Frontend targets wrong chain during development | Use `chains.foundry` (31337) in dev, switch for production |
| Missing `cast rpc anvil_setIntervalMining 1` | `block.timestamp` frozen in fork mode | Run after starting fork |
| `process.env.NEXT_PUBLIC_*` referenced but not set | Falls back to public RPC silently | Verify env vars are set on hosting platform, not just in code |
| Bare `http()` fallback in wagmi config | Silently hits public RPCs causing rate limits | Remove bare `http()` fallback transport |

---

## APPENDIX B: SE2 BRANDING CLEANUP CHECKLIST

Every item must be addressed. AI agents treat the scaffold as sacred — override this instinct.

### Footer (`packages/nextjs/components/Footer.tsx`)
- [ ] Remove "Built with SE2" text
- [ ] Remove BuidlGuidl links
- [ ] Remove "Fork me" link
- [ ] Remove support links
- [ ] Remove `nativeCurrencyPrice` badge (renders on ALL networks including Base mainnet)
- [ ] Replace with project's own content or clean footer

### Header / Title
- [ ] Tab title: app name only, NOT `"App | Scaffold-ETH 2"`
  - Check: `grep -rn "Scaffold-ETH" packages/nextjs/app/layout.tsx`
  - Fix: change `title.template` from `"%s | Scaffold-ETH 2"` to `"%s"`
- [ ] `appName` in `wagmiConnectors.tsx`: change from `"scaffold-eth-2"` to actual app name

### Visual
- [ ] Favicon: replace `packages/nextjs/public/favicon.ico` (not SE2 scaffold logo)
- [ ] OG image: custom 1200x630 PNG with absolute production URL
- [ ] `--radius-field: 0.5rem` in BOTH theme blocks in `globals.css`

### Content
- [ ] README.md: describes THIS project, not the SE2 template
- [ ] `manifest.json` / `site.webmanifest`: project name

### Functional
- [ ] Block explorer disabled for IPFS builds (rename to `_blockexplorer-disabled`)
- [ ] Burner wallet: `burnerWalletMode: "localNetworksOnly"` in `scaffold.config.ts`
- [ ] `pollingInterval: 3000` (not default 30000)
- [ ] RPC overrides configured with `process.env.NEXT_PUBLIC_*`

### Verification Commands

```bash
# Must find NOTHING:
grep -rn "Scaffold-ETH\|scaffold-eth-2\|BuidlGuidl\|Fork me" packages/nextjs/ --include="*.tsx" --include="*.ts" | grep -v node_modules | grep -v ".next"

# Must show project name, not SE2:
grep "title" packages/nextjs/app/layout.tsx
grep "appName" packages/nextjs/scaffold.config.ts
```

---

## APPENDIX C: QA AUDIT CHECKLIST (Full)

This is the complete checklist from the QA skill file. Every item is PASS or FAIL.

### Ship-Blocking (must all pass before deploy)

1. **Wallet Button** — Connect shows a BUTTON (`<RainbowKitCustomConnectButton />`), not text like "Please connect your wallet"
2. **Network Switch** — Wrong network shows "Switch to [Chain]" button
3. **One Button at a Time** — Connect → Network → Approve → Action, never simultaneous
4. **Approve Lock** — Both `approvalSubmitting` AND `approveCooldown` states on `disabled` prop
5. **Contract Verified** — Green checkmark on block explorer for every deployed contract
6. **Footer Clean** — No BuidlGuidl, no "Fork me", no SE2 support links, no `nativeCurrencyPrice`
7. **Tab Title** — App name, not "Scaffold-ETH 2"
8. **README** — Project-specific, not SE2 template
9. **Favicon** — Not SE2 default

### Should-Fix (must all pass before delivery)

10. **Contract Address** — Displayed with `<Address/>` component (blockie, ENS, copy, explorer link)
11. **Address Input** — Every address input uses `<AddressInput/>`, not raw `<input type="text">`
12. **USD Context** — Dollar values next to all token/ETH amounts
13. **OG Image** — Absolute production URL (not `/thumbnail.jpg`, not `localhost:3000`)
14. **Polling** — `pollingInterval: 3000` in scaffold.config.ts
15. **RPC Override** — Not using default SE2 Alchemy key; env var confirmed set
16. **Radius Field** — `--radius-field: 0.5rem` in both theme blocks (not `9999rem`)
17. **Error Messages** — Contract errors mapped to human-readable text, no raw hex
18. **Dark Mode** — Semantic theme tokens (`bg-base-200`), not hardcoded dark (`bg-[#0a0a0a]`)
19. **Button Loaders** — Inline `<span className="loading loading-spinner" />`, not `className="...loading"` on button
20. **Phantom** — `phantomWallet` in RainbowKit wallet list
21. **Mobile Deep Link** — TX fires first, `setTimeout(openWallet, 2000)` after
22. **Mobile Detection** — Checks WC session data, not just `connector.id`
23. **Mobile Skip** — No deep link when `window.ethereum` exists (in-app browser)
24. **External Contracts** — All registered in `externalContracts.ts` (not manually in `deployedContracts.ts`)
25. **Scaffold Hooks** — No raw wagmi `useWriteContract`/`useReadContract` in app code

### Verification Commands

```bash
# Ship-blockers
grep -rn "Please connect\|Connect your wallet to\|connect to continue" packages/nextjs/app/
grep -rn "BuidlGuidl\|Fork me\|scaffold-eth" packages/nextjs/ --include="*.tsx" | grep -v node_modules | grep -v ".next"
grep -rn "nativeCurrencyPrice" packages/nextjs/components/Footer.tsx

# Should-fix
grep -rn "useWriteContract\|useReadContract" packages/nextjs/app/ packages/nextjs/components/ | grep -v scaffold-eth
grep -rn 'type="text"' packages/nextjs/app/ | grep -i "addr\|owner\|recip\|0x"
grep -rn "9999rem" packages/nextjs/styles/globals.css
grep -rn '"loading"' packages/nextjs/app/
grep -rn 'bg-\[#0\|bg-black\|bg-gray-9\|bg-zinc-9' packages/nextjs/app/
grep -rn "scaffold-eth-2" packages/nextjs/scaffold.config.ts packages/nextjs/**/wagmiConnectors*
```

---

## APPENDIX D: SECURITY PATTERNS

### Contract Security

| Pattern | Rule |
|---------|------|
| Ownership | `Ownable2Step` over `Ownable` — prevents accidental transfer |
| Token transfers | `SafeERC20` — handles non-standard return values |
| Reentrancy | `ReentrancyGuard` on all external state-changing functions |
| Function order | CEI: Checks → Effects → Interactions |
| ERC4626 inflation | Virtual shares — override `_decimalsOffset()` to return 6+ |
| Slippage | Never `amountOutMinimum: 0`. Calculate from TWAP or use 1-3% tolerance |
| TWAP checks | BEFORE the swap, not after |
| Oracle freshness | Check `updatedAt` timestamp, reject stale prices |
| Principal tracking | Proportional reduction based on shares/totalSupply, not raw amounts |
| Access control | `onlyOwner` for admin functions, verify msg.sender for user functions |

### Secret Security

```bash
# Pre-commit checks — run before every commit
git diff --cached --name-only | grep -iE '\.env|key|secret|private'
grep -rn "0x[a-fA-F0-9]\{64\}" packages/
grep -rn "g.alchemy.com/v2/[A-Za-z0-9]" packages/
grep -rn "infura.io/v3/[A-Za-z0-9]" packages/
```

### .gitignore (must include)

```
.env
.env.*
*.key
broadcast/
cache/
node_modules/
```

---

## APPENDIX E: COMMAND REFERENCE

### Scaffold

```bash
npx create-eth@latest <name> --extension none --solidity-framework foundry --skip-install false
```

### Contract Development

```bash
yarn fork --network base           # Fork with real protocol state
cast rpc anvil_setIntervalMining 1 # Enable block progression
yarn deploy                        # Deploy to local fork
yarn deploy --network base         # Deploy to Base mainnet
yarn verify --network base         # Verify on Basescan (no API key needed)
forge build                        # Compile contracts
forge test                         # Run tests
forge test --fuzz-runs 1000        # Fuzz testing
```

### Frontend

```bash
yarn start                         # Dev server at localhost:3000
yarn build                         # Production build (needs env vars for IPFS)
yarn lint                          # Lint both packages
```

### IPFS

```bash
npx bgipfs init --token $BGIPFS_TOKEN --endpoint https://upload.bgipfs.com
npx bgipfs upload packages/nextjs/out
```

### Discovery

```bash
cast interface <address> --rpc-url $ALCHEMY_RPC_URL      # Get ABI from on-chain
cast call <addr> "name()(string)" --rpc-url $ALCHEMY_RPC_URL  # Verify contract identity
cast call <addr> "decimals()(uint8)" --rpc-url $ALCHEMY_RPC_URL
cast balance <addr> --rpc-url $ALCHEMY_RPC_URL
cast wallet address --private-key $PRIVATE_KEY
```

### Git / GitHub

```bash
gh auth status                     # Verify git user
gh repo create <user>/<repo> --public --source=. --push
gh issue create --title "..." --body "..." --repo <user>/<repo>
```

### Job Management (LeftClaw)

```bash
npx tsx scripts/jobs.ts list open
npx tsx scripts/jobs.ts get <jobId>
npx tsx scripts/work.ts accept <jobId>
npx tsx scripts/work.ts log <jobId> "<note>" <stage>
npx tsx scripts/work.ts complete <jobId> "<url>"
curl https://leftclaw.services/api/job/<id>/messages
```

---

## APPENDIX F: FILE INVENTORY

### SE2 Project Structure

```
leftclaw-service-job-XX/
├── packages/
│   ├── foundry/
│   │   ├── contracts/           # Solidity source files
│   │   ├── script/              # Deploy scripts (Deploy.s.sol)
│   │   ├── test/                # Forge tests
│   │   └── foundry.toml         # Foundry config (RPC URLs, chain settings)
│   └── nextjs/
│       ├── app/                 # Next.js pages (App Router)
│       │   ├── layout.tsx       # Root layout (title, metadata, fonts, OG)
│       │   ├── page.tsx         # Home page
│       │   └── blockexplorer/   # Disable for IPFS (rename to _blockexplorer-disabled)
│       ├── components/
│       │   ├── Footer.tsx       # SE2 branding to remove
│       │   ├── Header.tsx       # Navigation
│       │   └── scaffold-eth/    # SE2 components (<Address/>, <AddressInput/>, etc.)
│       ├── contracts/
│       │   ├── deployedContracts.ts   # AUTO-GENERATED — never edit
│       │   └── externalContracts.ts   # Manual — external contract ABIs
│       ├── hooks/scaffold-eth/  # SE2 hooks (useScaffoldReadContract, etc.)
│       ├── styles/globals.css   # Theme config (--radius-field here)
│       ├── scaffold.config.ts   # Chain, polling, RPC overrides, wallet mode
│       ├── polyfill-localstorage.cjs  # Node 25+ fix (MUST be here, not root)
│       └── out/                 # Static export output (upload this to bgipfs)
├── .env                         # Secrets (NEVER commit, NEVER Read)
├── .env.example                 # Template for required env vars
├── SPEC_REQUIREMENTS.md         # Numbered testable requirements
└── README.md                    # Project-specific (not SE2 template)
```

### Key Config Files

| File | What It Controls | Common Mistakes |
|------|-----------------|-----------------|
| `scaffold.config.ts` | Target chain, polling, RPC, wallet mode | Default 30s polling, missing RPC overrides |
| `foundry.toml` | Compiler settings, RPC endpoints | Missing Base RPC, wrong optimizer runs |
| `globals.css` | DaisyUI theme tokens | `--radius-field: 9999rem` left in both themes |
| `layout.tsx` | Title, metadata, OG image, fonts | SE2 title template, relative OG URL |
| `wagmiConnectors.tsx` | Wallet list, appName | Missing Phantom, appName still "scaffold-eth-2" |

---

## APPENDIX G: ERROR PATTERNS + AUTO-FIX STRATEGIES

### Compilation Errors

| Error Pattern | Cause | Auto-Fix |
|--------------|-------|----------|
| `DeclarationError: Identifier already declared` | Duplicate import or variable | Remove duplicate declaration |
| `TypeError: Member not found` | Wrong interface for external contract | Re-fetch ABI with `cast interface` |
| `ParserError: Expected ';'` | Syntax error | Fix syntax at indicated line |
| `undeclared identifier` | Missing import | Add OpenZeppelin/dependency import |

### Build Errors

| Error Pattern | Cause | Auto-Fix |
|--------------|-------|----------|
| `localStorage is not defined` | Node 25+ in static export | Add polyfill-localstorage.cjs in packages/nextjs/ |
| `Module not found` | Wrong import path | Check actual package exports, fix path |
| `Type error: deployedOnBlock` | SE2 scaffold bug | Type assertion (known issue) |
| `Export encountered errors on following paths` | Dynamic import in static export | Remove or lazy-load the problematic component |

### Deploy Errors

| Error Pattern | Cause | Auto-Fix |
|--------------|-------|----------|
| `insufficient funds` | Deployer wallet empty | Fund deployer: `cast send` from funded wallet |
| `nonce too low` | Previous tx pending | Wait or `cast nonce --pending` |
| `execution reverted` | Constructor logic failed | Check constructor args and external state |

### Verification Errors

| Error Pattern | Cause | Auto-Fix |
|--------------|-------|----------|
| `Already Verified` | Contract already verified | Not an error — proceed |
| `Contract source code already verified` | Same | Proceed |
| `Unable to verify` | Compiler mismatch or wrong args | Check foundry.toml compiler version matches deployment |

### Verify-Fix Loop Protocol

When a compilation or test fails after a fix:

1. Read the error message carefully
2. Identify the root cause (not the symptom)
3. Apply the minimal fix
4. Rebuild/retest
5. If test fails after a SECURITY fix: **fix the test, not the contract** — the test was asserting insecure behavior
6. Maximum 5 iterations before escalating

---

## APPENDIX H: MODEL ROUTING

Different stages have different complexity. Route to the right model tier:

| Tier | Model | Use For | Token Limit |
|------|-------|---------|-------------|
| Cheap | Haiku / fast mode | Shell commands, file reads, simple greps | 4096 |
| Medium | Sonnet | Frontend components, tests, deploy scripts, QA audit | 16384 |
| Expensive | Opus | Contract codegen, complex DeFi logic, security audit | 32768 |

### Per-Stage Routing

| Stage | Tier | Why |
|-------|------|-----|
| Phase 0: Spec | Medium | Planning, not implementation |
| Phase 1: Discovery | Cheap | Shell commands (cast interface) |
| Phase 2: Scaffold | Cheap | One command |
| Phase 3: Contracts | **Expensive** | Security-critical Solidity |
| Phase 4: Verification Gate | Medium | Reading + checking |
| Phase 5: Audit | **Expensive** | Security analysis |
| Phase 6: Fixes | **Expensive** | Security-critical changes |
| Phase 7: Deploy | Cheap | Shell commands |
| Phase 8: External Contracts | Medium | ABI wrangling |
| Phase 9: Frontend | Medium | React components |
| Phase 10: QA Audit | Medium | Checklist evaluation |
| Phase 11: QA Fixes | Medium | React fixes |
| Phase 12: IPFS Deploy | Cheap | Shell commands |
| Phase 13: Live Journey | Medium | Browser testing |
| Phase 14: README | Cheap | Text writing |
| Phase 15: Delivery | Cheap | Shell commands |

---

## APPENDIX I: COST MODEL

Target: **$2-5 per build** for standard dApps (single contract + frontend).

| Component | Est. Cost | Notes |
|-----------|-----------|-------|
| Opus contract codegen | $0.50-1.50 | Depends on contract complexity |
| Opus audit (20 specialists) | $0.50-1.00 | Parallelized |
| Sonnet frontend | $0.30-0.80 | Depends on UI complexity |
| Sonnet QA audit + fixes | $0.20-0.50 | |
| Cheap stages (shell, deploy) | $0.05-0.20 | |
| **Total** | **$1.55-4.00** | |

### Cost Optimization Rules

1. **Never retry the same failing command** — diagnose first, fix, then retry once
2. **Don't read entire codebases** — read only the files you need for the current stage
3. **Use cheap models for cheap tasks** — don't send `yarn build` output to Opus
4. **Parallelize audit specialists** — 20 cheap calls beat 1 expensive serial call
5. **Cache discovery results** — verified address table persists across stages
6. **Kill early on blockers** — if a fundamental assumption is wrong, stop the build and escalate before burning tokens on downstream stages

---

## STAGE DEPENDENCY GRAPH

```
Phase 0 (Spec) ─────────────────────┐
                                     │
Phase 1 (Discovery) ────────────────┤
                                     │
Phase 2 (Scaffold + Repo) ──────────┤
                                     │
Phase 3 (Write Contracts) ──────────┤
                                     │
Phase 4 (Contract Verification) ────┤
                                     │
Phase 5 (Contract Audit) ──────────┤
                                     │
Phase 6 (Contract Fixes) ──────────┤
                                     │
Phase 7 (Deploy + Verify) ─────────┤
                                     │
Phase 8 (External Contracts) ──────┤
                                     │
Phase 9 (Frontend Build) ──────────┤
                                     │
Phase 10 (Frontend QA Audit) ──────┤
                                     │
Phase 11 (Frontend QA Fixes) ──────┤
                                     │
Phase 12 (IPFS Deploy) ────────────┤
                                     │
Phase 13 (Live User Journey) ──────┤
                                     │
Phase 14 (README + Metadata) ──────┤
                                     │
Phase 15 (Delivery) ───────────────┘
```

Phases are strictly sequential. Each phase MUST pass its exit criteria before the next begins. On failure, fix and re-verify — never skip forward.

### Regression Rules

- **Phase 12 bug** → return to Phase 11 (fix frontend, rebuild)
- **Phase 13 bug (UI)** → return to Phase 11
- **Phase 13 bug (contract)** → return to Phase 3 (fix contract, re-audit, redeploy, rebuild frontend)
- **Phase 7 deploy failure** → return to Phase 6 (check contract fixes)

Never implement production workarounds. Go back to the right phase and fix it properly.

---

## ESCALATION PROTOCOL

When something is unresolvable by the agent:

1. **Identify the blocker** — what specifically is wrong
2. **Document what was tried** — commands run, errors received
3. **Post escalation message** to client via `POST /api/job/{id}/messages`
4. **STOP all work immediately** — do not try workarounds
5. **Set stage to `blocked`** — `logWork(jobId, "Blocked: <reason>", "blocked")`

Common escalation triggers:
- Client wallet has no ETH for ownership acceptance
- External protocol contract is paused or deprecated
- Spec requirement is contradictory or impossible
- Rate limit / API downtime after 3 retries

---

## PER-STAGE SUBAGENT PROMPT TEMPLATE

Every Opus invocation must include:

```
## Context
- Repo: ~/clawd/ethereum-servicer/builds/leftclaw-service-job-JOBID
- GitHub: clawdbotatg/leftclaw-service-job-JOBID
- Read ~/clawd/ethereum-servicer/CLAUDE.md (Known Build Footguns) before starting

## Your Task
[EXACTLY what this stage does]

## Deliverable
[EXACTLY what to return]

## Stop Condition
[What NOT to do — do NOT proceed to X]

## Git
- User: clawdbotatg
- Commit and push when done
- Commit message: "<stage>: <description>"
```

---

*This playbook is the synthesis of 6 production playbooks, 8 ethskills skill files, SE2 AGENTS.md, and hard-won lessons from Jobs #43 and #46. It is the source of truth for AI dApp building. When in doubt, re-read the relevant phase. When the phase is unclear, re-read the skill file. When the skill file conflicts with your training data, the skill file wins.*
