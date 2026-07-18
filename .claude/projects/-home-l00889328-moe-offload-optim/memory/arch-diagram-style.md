---
name: arch-diagram-style
description: "How the user wants architecture/feature diagrams drawn — ASCII, per-module shape labels, code-verified, review-before-doc-update."
metadata: 
  node_type: memory
  type: feedback
  originSessionId: f652567b-cd42-410e-8b12-66f48c5a230e
---

User's standing preference for architecture / feature diagrams (they draw many). Default to this every time.

**Format:** ASCII art in the terminal — NOT SVG/PNG/EdrawMax rendering, no colors. Matches the style of `moe_forward_flow.md` (workspace root). Box/arrow chars: `┌─┐│└┘`, `──▶ ▼ ▶`, and `╔══╗ ═ ║ ╚` for emphasized blocks (e.g. a `× N` loop). Start with a symbol legend (`T/H/I/E/topk/…` with this model's values); split into logical regions, each under its own header.

**Labeling:** put the tensor shape **before AND after every module** as `module  [in] → [out]`. Explicitly separate model-level (走一次) vs per-layer (×N) blocks. Mark data-consumption points where useful (e.g. `▸ topk_ids`, `◆ topk_weights`). Follow each diagram with a short 要点 (key-points) bullet list.

**Workflow:** draw → user reviews → iterate → only then update the doc. Do NOT write to docs before sign-off ("先画出来我看看再更新"). Verify every dimension/structure against actual code first — read the Python forward AND the C++ shape-inference (`csrc/**/torch_binding_meta.cpp`, the `construct_*_output_tensor` / `*_meta` functions); don't infer shapes from Python wrappers alone (I got `hc_pre`'s output shape wrong by reasoning — it collapses hc_mult, the meta fn proved it). Be precise on operators/conditions (`<` vs `<=`, draft-layer exclusions). See [[measure-before-optimize]].

**Source files:** originals are EdrawMax (`.eddx` = a ZIP of XML) + exported PNG. To read `.eddx`: unzip + parse `<tp>` text runs and `GPinX/GPinY` coords for precise text/structure (authoritative); PNG only adds visual/color. Cross-check image OCR against the XML — OCR misreads small text (e.g. `sqrtsoftplus`→`silu`, `tid2eid`→`b2d2d`).

**Where they live:** feature architecture diagrams go into / update `moe_forward_flow.md` and sibling feature docs at the workspace root.

**Why:** user will frequently need architecture diagrams for various MoE/offload features; wants consistent, reviewable, code-accurate ASCII they can eyeball in the terminal.

**How to apply:** whenever asked to draw / explain / verify an architecture or feature flow, default to this ASCII style, label per-module shapes, verify against code before finalizing, and show for review before editing any doc.
