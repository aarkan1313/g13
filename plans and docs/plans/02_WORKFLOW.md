# Workflow & Anti-Drift Protocol

**This is the most important document in the project for YOUR specific failure mode.**

Past attempts died not from bad code but from **plan divergence during unsupervised work**: progress happened at the desk with visual feedback, then unsupervised agent sessions drifted, accumulated changes, stopped matching any document, and became un-troubleshootable. This document exists to make that impossible — or at least loud and early instead of silent and fatal.

It is written to be read and obeyed by an AI coding agent (e.g. Claude Code) working without supervision. The human will read gates after the fact.

---

## 1. The Prime Directives (for the agent)

1. **Never deviate from the current milestone's defined steps.** If something the step requires turns out to be impossible or wrong, you STOP and write the problem into `DRIFT_LOG.md`. You do not invent a workaround that changes the architecture.
2. **One step at a time. Each step ends in a gate.** Do not start step N+1 until step N's gate is green. Do not batch steps.
3. **Never change the Field/Renderer contract** (signatures in `00_ARCHITECTURE.md` §2.1) without an explicit, human-approved doc change. If a step seems to need it, STOP and log it.
4. **If you cannot make a gate pass after 3 honest attempts, STOP.** Do not refactor the architecture to force it. Write the failure into `DRIFT_LOG.md` with: what you tried, the exact error, and your hypothesis. Leave the code in the last compiling state.
5. **The codebase must compile and run at the end of every step.** A step is not "done" if the project is red. If you must leave it red, the step failed — revert to the last green commit.
6. **Commit at every green gate** with the message format in §4. Never commit red.
7. **Do not add features not in the current milestone.** Not even small ones. Not even "while I'm here." Scope creep during unsupervised work is the disease. (See `ROADMAP.md` for what's deferred and why — it's deferred on purpose, not forgotten.)

---

## 2. What a "gate" is

Every step ends in ONE of two gate types. No step may end in "it should be better now."

- **Visual gate:** a screenshot-describable, binary condition.
  - GOOD: "Standing at spawn, you see continuous green terrain to the horizon with no holes, no flickering, no gaps between tiles."
  - BAD: "The terrain looks better."
- **Test gate:** an automated assertion that prints PASS/FAIL.
  - GOOD: "`cargo test field_determinism` passes: sampling (1000.0, 1000.0) returns the same value across 1000 trials and matches a stored golden value."
  - BAD: "The field seems deterministic."

Every step in `MILESTONE_*.md` specifies its gate explicitly. If a step in those docs lacks a clear gate, that is a documentation bug — STOP and log it; do not guess.

### The two-track gate system (this directly addresses your work/desk split)
- **Test gates** can be verified by the agent ALONE, unsupervised, with no human and no eyeballs. The agent runs them and proceeds.
- **Visual gates** require the human. The agent CANNOT self-certify a visual gate. When the agent reaches a visual gate while unsupervised, it:
  1. Brings the project to the green/compiling state that *should* satisfy the gate.
  2. Writes into `DRIFT_LOG.md`: "Reached visual gate [name]. Believe it is satisfied. Awaiting human visual confirmation. Did NOT proceed."
  3. **STOPS.** It does not start the next step.

This is the core trick: **unsupervised work may only proceed across test gates.** Anything needing your eyes parks and waits. So you can never come home to 8 hours of unverified visual drift — at most you come home to one parked gate.

---

## 3. The DRIFT_LOG.md protocol

`DRIFT_LOG.md` is an append-only log. The agent writes to it; the human reads it first thing each session. Every entry:

```
## [DATE TIME] — [STEP ID]
TYPE: [BLOCKED | PARKED-FOR-VISUAL | CONTRACT-CHANGE-NEEDED | DEVIATION-AVERTED]
WHAT I WAS DOING:
WHAT HAPPENED:
WHAT I TRIED (if blocked):
EXACT ERROR / STATE:
MY HYPOTHESIS:
CODEBASE STATE: [green at commit <hash> | red — reverted to <hash>]
WHAT I DID NOT DO: (e.g. "did not change the contract", "did not start next step")
```

The human's first action every session: read `DRIFT_LOG.md` top to bottom. This is how you re-sync after being away. No more "what changed while I was gone?" — it's all here.

---

## 4. Commit discipline

- Commit ONLY at green gates.
- Message format: `[M<milestone>.<step>] <gate that passed>` — e.g. `[M1.4] chunks stream in/out around viewer, no leak over 5min`.
- Tag the end of each milestone: `git tag m1-complete`.
- **The golden rule of recovery:** because every commit is a green gate, you can always `git reset --hard` to the last working state and lose at most one step. This is the safety net that makes unsupervised work survivable.

---

## 5. Session ritual (human)

**Start of desk session:**
1. Read `DRIFT_LOG.md`.
2. Resolve any `PARKED-FOR-VISUAL` gates by actually looking. Mark pass/fail.
3. Resolve any `CONTRACT-CHANGE-NEEDED` by deciding and updating `00_ARCHITECTURE.md` if approved.
4. Confirm the current step pointer in `PROGRESS.md` is correct.

**Before leaving for work (handing off to unsupervised agent):**
1. Confirm the project is green.
2. Confirm the next steps queued for the agent are **test-gated only** (or expect it to park at the first visual gate — that's fine).
3. The agent works forward across test gates and parks at the first visual gate. That's the contract.

---

## 6. PROGRESS.md

A dead-simple single source of truth for "where are we." One line per step:

```
M1.1 [x] gdext skeleton loads, hot reload works
M1.2 [x] one GPU page produced + readback determinism test passes
M1.3 [ ] <- CURRENT
...
```

The agent updates this at every green gate. The human reads it to know the state at a glance. If `PROGRESS.md` and reality disagree, reality wins and the agent must log the discrepancy.

---

## 7. The "tuning vs building" rule

You said you like to *tune* (sliders, params) and that's where it feels good. Tuning and building are different modes:

- **Building** changes code/structure. Gated, logged, committed, agent-or-human.
- **Tuning** changes only `WorldConfig` values (seed, noise params, etc.) at the desk, live, via hot reload. Tuning NEVER requires a code change — if it does, that's a building task and goes through the gate process.

Keep these separate. Tuning is your reward loop; don't let it quietly turn into unlogged building.
