---
name: commit-style
description: "How the user wants commits cleaned up — strip Co-Authored-By, keep Signed-off-by, concise accurate messages."
metadata: 
  node_type: memory
  type: feedback
  originSessionId: dab01221-9e76-4ee5-ac7f-73d7a9e4765d
---

When squashing/cleaning commits for this user, the message must:
- Have NO `Co-Authored-By` trailer (especially `Co-Authored-By: Claude`).
- End with `Signed-off-by: LookAround0301 <lixushi@huawei.com>`.
- Be concise AND accurate to the *combined* change — don't keep a stale body that contradicts the new diff (rewrite it).

**Why:** Expressed twice on 2026/06/14 (vllm and vllm-ascend). They fold AI-assisted commits into clean human-authored ones for upstream PRs, and want the message to actually match what the commit does (caught a case where the kept message claimed reshapes were *added* after they'd been removed).

**How to apply:** Use `git commit --amend` when the target commit is HEAD (avoids interactive rebase). Always verify the commit isn't pushed first — if it's local-only (`ahead N` of origin), amend is safe and a normal push works (no force). Exclude build artifacts (e.g. `csrc/build_out/`) — add only the intended source files. See [[weight-load-optimization]].
