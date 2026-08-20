# Login cleanup — remove duplicate & dead account dirs (per-box)

Run this **when the fleet is quiet** (no audit VMs running, harness not mid-refresh).
It removes the wasted login dirs that concentrate load onto too few pools. This is
the last big efficiency leak after the delivery-hold fix (`555b487`).

> **Why this matters.** A subscription pool is an **org**, not a directory. When two
> dirs hold the same org, they are a **forked credential store**: OAuth refresh
> *rotates* the refresh token, so whichever dir refreshes last silently kills the
> others. Three dirs on one plan means two are usually dead weight, and the router
> can waste a boot selecting a corpse. **The fix is deletion, never re-sign-in** —
> re-signing in re-forks the store and restarts the same clock.

---

## This box (clawd-leftclaw) — measured 2026-08-20

8 dirs → **4 real pools** + 2 empties:

| dir | org (pool) | plan | verdict |
|---|---|---|---|
| `ef` | bba673c2 | Ethereum Foundation | **EF trio — keep exactly ONE** |
| `austinmax` | bba673c2 | Ethereum Foundation | (a live harness session is bound here) |
| `sub2` | bba673c2 | Ethereum Foundation | |
| `sub3` | 900e6f32 | austingriffith | **keep** |
| `sub4` | 18f36efd | slop | **keep** |
| `sub5` | 94f7f5f0 | clawd@buidlguidl | **keep** (fleet's current `claude-source`) |
| `clawd` | — (no `.claude.json`) | — | **delete — empty junk** |
| `sub6` | — (no token) | — | **delete — empty junk** |

**End state: 4 dirs — one EF dir, `sub3`, `sub4`, `sub5`.**

> Re-measure before running — tokens rotate. Regenerate this table with the
> ground-truth snippet in **Step 0**; don't trust this static copy.

---

## Step 0 — Re-measure (read-only, always safe)

```bash
cd ~/clawd/clawd-harness/projects/clawd-containers
python3 - <<'PY'
import json, glob, os, hashlib, unicodedata, subprocess
for d in sorted(glob.glob(os.path.expanduser("~/.clawd-accounts/*"))):
    if not os.path.isdir(d): continue
    name=os.path.basename(d); cj=os.path.join(d,".claude.json")
    org=email="—"
    if os.path.exists(cj):
        o=(json.load(open(cj)).get("oauthAccount") or {})
        org=(o.get("organizationUuid") or "—")[:8]; email=o.get("emailAddress") or "—"
    else: org="(no .claude.json)"
    h=hashlib.sha256(unicodedata.normalize("NFC",d).encode()).hexdigest()[:8]
    svc=f"Claude Code-credentials-{h}"
    t=subprocess.run(["security","find-generic-password","-s",svc,"-w"],capture_output=True,text=True)
    print(f"{name:<12} org={org} tok={'yes' if t.stdout.strip() else 'NO ':<3} slot={svc}  {email}")
PY
```

Group dirs by `org=`. Any org with 2+ dirs is a duplicate set. Any dir with
`tok=NO` **and** no `.claude.json` is empty junk.

---

## Step 1 — Confirm the fleet is idle

```bash
tart list | awk '$NF=="running"'          # must print nothing
launchctl list | grep leftclaw.wrangler   # note it's up; we won't restart it
cat ~/.config/cont/claude-source          # which dir the fleet points at — do NOT delete this one
```

If a VM is running, wait — deleting a dir mid-audit corrupts a running login.

---

## Step 2 — Delete the empty junk (`clawd`, `sub6`) — safe, no token to lose

For each empty dir (verify `tok=NO` + no `.claude.json` in Step 0 first):

```bash
D="$HOME/.clawd-accounts/clawd"     # then repeat for sub6
SLOT="Claude Code-credentials-$(python3 -c "import hashlib,unicodedata,os;print(hashlib.sha256(unicodedata.normalize('NFC',os.path.expanduser('$D')).encode()).hexdigest()[:8])")"
security delete-generic-password -s "$SLOT" 2>/dev/null || true   # orphan slot, if any
rm -rf "$D"
```

---

## Step 3 — Collapse the EF trio (`austinmax`, `ef`, `sub2`) to one

**Do not pick by name — pick the one whose token actually works right now.** The
other two may already be rotated dead.

**3a. Find the live one.** Ping each under its own config dir (this is the only
safe refresh — a real `claude -p`, never a hand-rolled token call):

```bash
for d in austinmax ef sub2; do
  echo -n "$d: "
  CLAUDE_CONFIG_DIR="$HOME/.clawd-accounts/$d" \
    claude -p 'reply with OK' --model claude-haiku-4-5-20251001 >/dev/null 2>&1 \
    && echo LIVE || echo dead
done
```

Keep the **first `LIVE`** dir → call it `$KEEP`. If more than one is LIVE, prefer
the one already in use (`austinmax` — a session is bound to it) to avoid a re-point.

**3b. If `$KEEP` is NOT `austinmax`, re-point the bound session first.** A harness
session records `austinmax` as its `config_dir`. Before deleting austinmax:
either let that session finish/idle out, or point the fleet + harness at `$KEEP`
and let the session rebind on its next handoff. Simplest: if austinmax is LIVE,
make it `$KEEP` and skip this.

**3c. Delete the two losers** (the EF dirs that are not `$KEEP`):

```bash
for d in <the two EF dirs that are NOT $KEEP>; do
  D="$HOME/.clawd-accounts/$d"
  SLOT="Claude Code-credentials-$(python3 -c "import hashlib,unicodedata;print(hashlib.sha256(unicodedata.normalize('NFC','$D').encode()).hexdigest()[:8])")"
  security delete-generic-password -s "$SLOT" 2>/dev/null || true
  rm -rf "$D"
done
```

---

## Step 4 — Verify

```bash
cont account list          # should show 4 pools, one dir each, all readable
bash scripts/fleet-health.sh   # the "LOGGED OUT / duplicates" flags should be gone
```

Expected dirs left: **one EF dir, `sub3`, `sub4`, `sub5`.**

---

## Rules that keep this safe

- **Never two live copies of one org at once** — that's what kills tokens.
- **Never re-sign-in to fix a duplicate** — deletion only. Re-login re-forks the store.
- **The login is in the macOS keychain, not the folder** — keyed by the dir's full
  path hash. A plain `mv` orphans it; that's why we delete-then-forget, not rename.
- **Per-box.** Other boxes have different dir sets — re-run Step 0 on each; never
  assume a dir name means the same plan elsewhere.
- Don't delete the dir named in `~/.config/cont/claude-source` unless you re-point
  it first.

Related: `SUBSCRIPTION-DRAIN-2026-08-17.md` §2–3 (the clawd-head rename, keychain
trap in depth), and the "Subscription burn" section of `CLAUDE.md`.
