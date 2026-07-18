---
name: measure-before-optimize
description: "User prefers confirming a bottleneck with instrumentation before optimizing, and acting on measured data not hypothesis."
metadata: 
  node_type: memory
  type: feedback
  originSessionId: dab01221-9e76-4ee5-ac7f-73d7a9e4765d
---

When asked to optimize something slow, the user wants the bottleneck distribution confirmed with instrumentation BEFORE code changes — not a hypothesis-driven refactor.

**Why:** In the weight-load work my first hypothesis (the NZ round-trip) was wrong; the actual cause was single-threaded strided transpose-copies. The user explicitly chose "先按照 a 来确认瓶颈分布" (do the measurement option first) when offered measure-vs-implement choices.

**How to apply:** Add lightweight phase-level timing first, have the user run once, read the numbers, then propose the fix grounded in that data. Keep the instrumentation cheap (no invasive syncs unless justified) and removable. Reinforced in [[weight-load-optimization]].
