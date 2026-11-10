#!/usr/bin/env python3
"""Regression suite for the delivery gate: scripts/leftclaw/pipeline_gate.py
and the hook in scripts/leftclaw/complete.sh.

Run: python3 tests/test_pipeline_gate.py     (exit 0 = pass; offline, ~2s)

The gate refuses `completeJob` for a Solidity audit whose session log does not
show the multi-agent pipeline ran. Both directions matter:
  * it must REFUSE a one-pass audit (the failure it exists for: ~46 audits,
    jobs 975-1206), and must not be fooled by old sessions baked into the image;
  * it must never strand a legitimate delivery — full runs, non-Solidity
    targets, other agent types, host-auditor, an unreadable log.

Everything runs against a throwaway $HOME with a stub `cast`, so nothing here
can reach a chain.
"""
import json
import os
import shutil
import stat
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.normpath(os.path.join(HERE, ".."))
LC = os.path.join(ROOT, "scripts", "leftclaw")
FAILED = []
BOOT = time.time() - 3600          # "the VM booted an hour ago"


def check(name, got, want):
    if got == want:
        print(f"  ok   {name}")
    else:
        print(f"  FAIL {name}\n         got:  {got!r}\n         want: {want!r}")
        FAILED.append(name)


class Box:
    """A fake auditor VM home."""

    def __init__(self, auditor=True, sol=True, job="77"):
        self.home = tempfile.mkdtemp(prefix="gate-")
        self.job = job
        self.bin = os.path.join(self.home, "bin")
        os.makedirs(self.bin)
        self.calls = os.path.join(self.home, "cast-calls.log")
        stub = os.path.join(self.bin, "cast")
        with open(stub, "w") as fh:
            fh.write("#!/bin/bash\necho \"$@\" >> \"%s\"\n"
                     "echo '{\"transactionHash\":\"0xabc\",\"status\":\"0x1\"}'\n" % self.calls)
        os.chmod(stub, os.stat(stub).st_mode | stat.S_IEXEC)
        if auditor:
            open(os.path.join(self.home, "auditor.prompt.md"), "w").write("x")
        src = os.path.join(self.home, "audits", job, "repo", "src")
        os.makedirs(src)
        open(os.path.join(src, "Vault.sol" if sol else "app.js"), "w").write("// x\n")
        self.proj = os.path.join(self.home, ".claude", "projects", "-Users-admin")

    def session(self, name, agents, tool="Agent", old=False, dup=False, subfiles=None):
        os.makedirs(self.proj, exist_ok=True)
        path = os.path.join(self.proj, name + ".jsonl")
        with open(path, "w") as fh:
            fh.write(json.dumps({"type": "user", "message": {"content": "go"}}) + "\n")
            for i in range(agents):
                line = json.dumps({"type": "assistant", "message": {"content": [
                    {"type": "text", "text": "spawning"},
                    {"type": "tool_use", "id": f"{name}-tu{i}", "name": tool,
                     "input": {"model": "fable", "prompt": "..."}}]}})
                fh.write(line + "\n")
                if dup:                       # streamed duplicate of the same call
                    fh.write(line + "\n")
            # a mention of the tool that is NOT a spawn must not count
            fh.write(json.dumps({"type": "user", "message": {"content": [
                {"type": "tool_result", "content": '"name":"Agent" tool_use'}]}}) + "\n")
        n_sub = agents if subfiles is None else subfiles
        sub = os.path.join(self.proj, name, "subagents")
        os.makedirs(sub, exist_ok=True)
        for i in range(n_sub):
            open(os.path.join(sub, f"agent-{i}.jsonl"), "w").write("{}\n")
            open(os.path.join(sub, f"agent-{i}.meta.json"), "w").write("{}\n")
        if old:
            t = BOOT - 86400
            for dp, _dn, fns in os.walk(self.proj):
                for fn in fns:
                    if fn.startswith(name) or os.path.basename(os.path.dirname(dp)) == name:
                        os.utime(os.path.join(dp, fn), (t, t))
            os.utime(path, (t, t))

    def env(self, **extra):
        e = dict(os.environ, HOME=self.home, PATH=self.bin + os.pathsep + os.environ["PATH"],
                 PRIVATE_KEY="0x01", ALCHEMY_API_KEY="k", PIPELINE_GATE_SINCE=str(BOOT))
        e.pop("PIPELINE_GATE", None)
        e.pop("PIPELINE_MIN_AGENTS", None)
        e.update(extra)
        return e

    def gate(self, *args):
        r = subprocess.run([sys.executable, os.path.join(LC, "pipeline_gate.py"), self.job, *args],
                           capture_output=True, text=True, env=self.env(), timeout=60)
        return r.returncode, r.stdout + r.stderr

    def complete(self, *args, **env):
        r = subprocess.run(["/bin/bash", os.path.join(LC, "complete.sh"), self.job,
                            "https://example.invalid/report.md", *args],
                           capture_output=True, text=True, env=self.env(**env), timeout=60)
        sent = open(self.calls).read() if os.path.exists(self.calls) else ""
        return r.returncode, sent, r.stdout + r.stderr

    def close(self):
        shutil.rmtree(self.home, ignore_errors=True)


def test_gate():
    print("pipeline_gate.py")

    b = Box(); b.session("live", 23)
    check("full run (23 agents) passes", b.gate()[0], 0); b.close()

    b = Box(); b.session("live", 20)
    check("exactly the minimum (20) passes", b.gate()[0], 0); b.close()

    b = Box(); b.session("live", 19)
    check("one short (19) is refused", b.gate()[0], 3); b.close()

    # THE failure this exists for: a manual single pass, zero agents.
    b = Box(); b.session("live", 0)
    rc, out = b.gate()
    check("one-pass audit (0 agents) is refused", rc, 3)
    check("refusal tells the auditor what to run", "two-phase-audit-v3.md" in out, True)
    check("refusal names small scope as not a reason", "small or single-file scope" in out, True)
    b.close()

    # jobs 979/1029/1155: a cut-down fan-out is still not the product.
    b = Box(); b.session("live", 5)
    check("cut-down run (5 agents) is refused", b.gate()[0], 3); b.close()

    # Sessions baked into the gold image predate boot and must not count.
    b = Box(); b.session("baked", 30, old=True); b.session("live", 2)
    rc, out = b.gate()
    check("agents from before boot do not count", rc, 3)
    check("…and the count shown is this boot's", "shows 2 sub-agent" in out, True)
    b.close()

    # A restarted session in the same VM: spawns add up across sessions.
    b = Box(); b.session("first", 11); b.session("second", 12)
    check("spawns add up across this boot's sessions", b.gate()[0], 0); b.close()

    # Streamed duplicates of one call are one spawn, and a tool_result that
    # merely quotes the tool name is none.
    b = Box(); b.session("live", 10, dup=True, subfiles=10)
    rc, out = b.gate()
    check("duplicate transcript lines are not double counted", rc, 3)
    check("…count is 10, not 20", "shows 10 sub-agent" in out, True)
    b.close()

    # A CLI update renames the tool: the per-agent logs still prove the run.
    b = Box(); b.session("live", 22, tool="Subagent")
    check("renamed spawn tool: per-agent logs still count", b.gate()[0], 0); b.close()

    # Not this pipeline's job.
    b = Box(sol=False); b.session("live", 0)
    rc, out = b.gate()
    check("no Solidity under ~/audits/<job> passes", rc, 0)
    check("…and says it was not checked", "not checked" in out, True)
    b.close()

    # Fail open when the evidence is unreadable — never strand a paid job.
    b = Box()
    rc, out = b.gate()
    check("no session log at all fails OPEN", rc, 0)
    check("…loudly", "WARNING" in out, True)
    b.close()

    # Operator override (set from the host, not offered to the auditor).
    b = Box(); b.session("live", 0)
    open(os.path.join(b.home, ".pipeline-override"), "w").write("Austin: resend 1205\n")
    check("operator override file passes", b.gate()[0], 0)
    b.close()
    b = Box(); b.session("live", 0)
    check("refusal does not advertise the operator override",
          ".pipeline-override" in b.gate()[1], False)
    b.close()

    b = Box(); b.session("live", 7)
    check("--count prints the number", b.gate("--count")[1].strip(), "7"); b.close()


def test_complete():
    print("complete.sh")

    b = Box(); b.session("live", 0)
    rc, sent, out = b.complete()
    check("refused audit: exit 3", rc, 3)
    check("refused audit: completeJob was NOT sent", sent, "")
    b.close()

    b = Box(); b.session("live", 23)
    rc, sent, out = b.complete()
    check("full audit: exit 0", rc, 0)
    check("full audit: completeJob sent once", sent.count("completeJob"), 1)
    b.close()

    # Other agent types and host-auditor share complete.sh and are not audits
    # run in an auditor VM: no marker, no gate.
    b = Box(auditor=False); b.session("live", 0)
    rc, sent, out = b.complete()
    check("no auditor marker (builder VM / host-auditor): not gated", rc, 0)
    check("…completeJob sent", sent.count("completeJob"), 1)
    b.close()

    # A Solidity repo whose scope is not Solidity.
    b = Box(); b.session("live", 0)
    rc, sent, out = b.complete("--not-solidity", "browser JavaScript diff, web/*.js only")
    check("--not-solidity with a reason delivers", rc, 0)
    check("…and writes the on-chain delivery-check note first",
          sent.index("logWork") < sent.index("completeJob"), True)
    check("…note carries the reason", "browser JavaScript diff" in sent, True)
    b.close()

    b = Box(); b.session("live", 0)
    rc, sent, out = b.complete("--not-solidity", "small")
    check("--not-solidity without a real reason is rejected", rc, 2)
    check("…nothing sent", sent, "")
    b.close()

    b = Box(); b.session("live", 0)
    rc, sent, out = b.complete(PIPELINE_GATE="0")
    check("PIPELINE_GATE=0 (operator kill switch) delivers", rc, 0)
    b.close()


if __name__ == "__main__":
    test_gate()
    test_complete()
    if FAILED:
        print(f"\n{len(FAILED)} FAILED: {', '.join(FAILED)}")
        sys.exit(1)
    print("\nall pipeline-gate tests passed")
