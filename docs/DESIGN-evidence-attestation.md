# Design note — what would make an acceptance checkable

| | |
|---|---|
| **Written at** | patch 441b, 22 August 2026, after Task 0A's record was accepted |
| **Status** | **Design only. Nothing here is built.** A staged proposal, with one tier recommended, one costed and deferred, and one rejected with a reason |
| **Belongs to** | **Task 10** — "Build the external evidence-artifact auditor and exact dataset binding" — see §6 |
| **Authority for what exists today** | `scripts/evidence-manifest.py`, `docs/evidence/post-b5/manifest.schema.json`, ADR §12.193 |

---

## 1. The gap, stated precisely — and it is not "no signature"

Every field in a manifest is checkable **except the one that matters most.**

| field | how it is checked today | can it be forged by editing the file? |
|---|---|---|
| `tree.digest` | recomputed from the sources | **no** — it is a function of the tree |
| `evidence[].sha256` / `bytes` | recomputed from the files | **no** |
| `predecessors[].sha256` | recomputed from that manifest | **no** |
| `binding.commit` = `tree.commit` | compared | no, but see below |
| **`status: "accepted"`** | *nothing* | **yes** |
| **`approval.by` / `atUTC` / `statement`** | shape only | **yes** |

The validator refuses `accepted` without an approval **signed by the owner** — but
"signed" there means *a string equal to `owner`*. **It checks internal consistency,
not authenticity.** Everything else in the manifest is self-checking because it can
be recomputed from an independent artifact. The approval cannot, because there is no
independent artifact.

So the honest one-line statement of the gap is:

> **Nothing distinguishes "Bruno accepted this" from "the file says Bruno accepted
> this", and nothing distinguishes "this is what he accepted" from "this is what the
> file says now".**

The second half is the more useful half, and §3 is why.

---

## 2. Get the threat model right, because it changes the answer

This is a one-person repository for a personal training app. **Nobody is
impersonating Bruno, and he will never dispute his own approval.** Identity proof
and non-repudiation — the two things signatures are for — are worth close to nothing
here.

What can actually go wrong:

1. **A future session reads a draft as accepted**, because it skimmed the word rather
   than the validator's verdict.
2. **A record is edited after acceptance** — a number corrected, a sentence softened —
   and nothing says so. Later tasks then key off a record nobody re-accepted.
3. **An acceptance claims a tree it never saw** — the timestamps and the commit are
   whatever somebody typed.
4. **History is rewritten** — an amend or a force-push moves the commit the record
   names.

**What is needed is tamper-evidence, ordering and freshness. Not identity.** Reaching
for GPG because the runbook's prompt used the word *signature* would be answering a
question nobody asked — and this project has a rule about that (§12.164: ask the
function, not its ingredients).

---

## 3. TIER 1 — free, no new secrets, and it closes most of the model

### 3.1 The rule that does the most work, and costs nothing

> **An accepted manifest is committed exactly once and is never edited again. If it
> must change, a NEW manifest supersedes it and cites the old one as a predecessor
> by hash.**

That is not a convention to remember; it is mechanically checkable:

```
git log --format=%H -- docs/evidence/post-b5/task-0a.json   →  exactly one commit
git rev-parse <that commit>:docs/evidence/post-b5/task-0a.json  →  blob equals HEAD's
```

**Failure 2 disappears entirely**, and the predecessor chain 438 already built becomes
the supersession mechanism rather than decoration. It also matches the workflow Task
0A actually used: validate as a draft, accept, validate again at the same tree, commit
once.

### 3.2 Three self-asserted fields become three cross-checked ones

A `--require-git` mode would add:

| check | catches |
|---|---|
| `tree.commit` exists as a commit object | a typed or invented sha |
| the manifest's commit is a **descendant** of `tree.commit` | an acceptance describing a tree that did not exist yet |
| `approval.atUTC` lies between `tree.commit`'s committer date and the manifest's commit date | an approval back-dated before its own evidence, or forward-dated after it was recorded |
| every `evidence[].path` is **tracked** at that commit, blob hash equal to the recorded sha256 | evidence that exists on disk but was never committed |

Cost: the validator already shells out to `git rev-parse HEAD`, so the dependency is
not new. **No keys. No custody decision. Nothing to back up or rotate.**

### 3.3 The independent witness that already exists

The repository is pushed to `github.com/BrunoVdS/sub4`. **Once a commit is pushed, its
sha is recorded by a third party**, and a local amend or rebase cannot change what the
remote already saw:

```
git fetch && git merge-base --is-ancestor <acceptingCommit> origin/main
```

That is free anchoring with a party already trusted with the whole repository — no
new secret, nothing extra sent anywhere.

**Its weakness, stated rather than glossed: a force-push moves the remote too.** The
mitigation is a GitHub ruleset blocking force-push on the default branch, which is a
settings change and not code. Recommended alongside, and it is the only part of Tier 1
that lives outside this repository.

---

## 4. TIER 2 — real signing, and what it would actually cost here

**Checked rather than assumed, 22 August 2026:**

- `git version 2.50.1` — SSH signing (`gpg.format = ssh`, git ≥ 2.34) is available.
- `git remote -v` → **HTTPS**, not SSH.
- `ls ~/.ssh/*.pub` → **no keys at all on this machine.**
- `gpg.format`, `user.signingkey`, `commit.gpgsign` → all unset.

**So this is not "reuse the key you already have".** There is no key. Tier 2 means
*creating a new private key and deciding where it lives, how it is backed up, and what
happens when it is lost* — a new standing secret, for a threat nobody in §2 is facing.
That is the whole cost, and it is why this tier is costed rather than recommended.

If it is adopted, the shape:

1. **Acceptance moves out of the mutable JSON and into an immutable signed object.**
   `git tag -s evidence/task-0a <commit>` with the approval statement in the tag
   message. `status: accepted` in the JSON becomes a **claim**; `git tag -v` becomes
   the **proof**.
2. `allowed_signers` committed to the repository, so a fresh clone can verify without
   anything from the machine that signed.
3. The validator gains `--require-signature`, which shells out to `git verify-tag` and
   fails when the tag is missing, unsigned, or signed by a key not in `allowed_signers`.
4. The key is passphrase-protected and held with `ssh-add --apple-use-keychain`, so an
   acceptance costs one prompt.

**And the caveat that has to be written down beside it:** a signature proves *the key
signed*, not *that Bruno signed*. In a one-person repository those are the same
sentence — and saying otherwise would be exactly the dressing-up this note exists to
avoid.

---

## 5. TIER 3 — rejected, and the reason matters

**RFC 3161 timestamping, or anchoring a hash publicly.** It would prove to a stranger
that a hash existed at a given time.

**There is no stranger.** And it means sending a hash to a third party, which this
project does not do without a declared reason — the entire release-gate design exists
because "each switch controls a request that leaves this phone". A manifest hash is
harmless, and the rule still deserves respect when the payload is harmless, because
that is when rules get quietly dropped.

Recorded here so it is visibly **rejected with a reason** rather than looking like
something nobody thought of.

---

## 6. Where this goes in the plan

**Task 10 — "Build the external evidence-artifact auditor and exact dataset
binding".** It is already the read-only, external, verification-only task, and it
already owns "separate versioned identities bind validated source artifacts …
without hashing their own ledger/receipt fields".

But Task 10's exit gate is about the **dataset**. This is about the **record**. One
sentence would cover it:

> *An accepted evidence manifest is committed once and never edited; the auditor
> re-derives its tree digest, evidence hashes and predecessor chain, and refuses any
> manifest whose approval is not bracketed by the commit dates of the tree it names
> and its own introduction.*

**Tier 1 does not need to wait for Task 10.** It is one patch against
`scripts/evidence-manifest.py` plus fixtures, and it can land whenever the runbook
allows a tooling patch. Tier 2 waits on a key-custody decision that is Bruno's alone
and has no deadline.

---

## 7. What happens next, with no work at all

**Task 0B's manifest will cite Task 0A's by hash.** That is the predecessor mechanism
438 built, used for the first time — and from that moment a change to the accepted
0A record breaks 0B's validation, without keys, without git, and without anybody
remembering to check. It is worth noticing that the cheapest tier of all is the one
already shipped and simply not yet exercised.
