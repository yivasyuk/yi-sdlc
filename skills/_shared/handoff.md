# Stage handoff — what every skill prints when it finishes (the output contract)

> **Reference-only.** Not a skill. **Every** skill ends by emitting the handoff block defined here —
> as its **last output**, after it has proposed its commit. The format lives only in this file; each
> skill keeps a one-line pointer and supplies its own *What I did* / *Review* / *next command*. This
> exists because a bare «Next: …» line is hard to act on — the user can't tell what changed, which
> files to open, or what to run next without scrolling back.

## TL;DR (короткий вступ українською)

Кожен крок (skill) наприкінці **завжди** друкує однаковий хендоф-блок із трьох секцій:

1. **What I did** — що стадія зробила + який коміт запропонувала (не змушуй гортати вгору).
2. **Review before continuing** — посилання на файли, які стадія створила/змінила і які треба
   глянути на цьому геті (реальні `docs/features/<slug>/…` шляхи — клікабельні/копіювані).
3. **Run next** — спершу `/clear` (обов'язково для forward-переходу — наступна стадія перечитує
   все з диска), потім наступна команда `/yi-sdlc:<next> <slug>` у **fenced-блоці** (копіюється в один
   клік) + альтернатива-пропуск, якщо вона є.

Це прибирає головний біль: «погано виводить, незручно копіювати і перевіряти».

---

## The block (sectioned format)

```md
## ✅ <skill> — <slug>

**What I did**
- <1–3 bullets: the artifact(s) produced/changed + the commit proposed>

**Review before continuing**
- `docs/features/<slug>/<file>` — <what to check here>
- `docs/features/<slug>/<file2>` — <…>

**Run next**
1. `/clear` — mandatory (fresh context; the next stage re-reads its inputs from disk)
2. then run:
   ```
   /yi-sdlc:<next> <slug>
   ```
   ↳ or `/yi-sdlc:<alt> <slug>` to <skip condition>   ← only when a real skip exists
```

Rules for filling it:

- **Always emit it** as the final output, once per run, after the commit is proposed. Never end a
  skill on a bare «Next: X».
- **What I did** — concrete and self-contained: name the files written and the proposed commit
  message, so the user doesn't scroll up to reconstruct it.
- **State the size used.** *What I did* names the `feature_size` the stage worked at — «size M (from
  `.size`)»; if the stage had to **default** because `.size` was missing, say so loudly — «size M
  (default — no `.size`; run `/yi-sdlc:classify-size <slug>`)» — so a missing size surfaces at this gate,
  not three stages later. (`write-prd` establishes `.size` at the start, so this should be rare.)
- **Review before continuing** — list **every artifact this stage wrote or changed**, each as a real
  `docs/features/<slug>/…` path (or repo-root path like `docs/architecture-map.md`) plus a one-liner
  on what to eyeball. This *is* the per-gate review checklist.
- **Run next** — the next command in **`/yi-sdlc:<name> <slug>`** form inside a fenced code block (so the
  user copies it in one click). `/clear` is step 1 and **mandatory** for a forward backbone handoff.
  Add a `↳ or …` skip-alternative **only** when one genuinely exists (see the table).
- Keep the `<slug>` substituted with the real slug — never leave the literal `<slug>` in the printed
  block.

## Variants

- **Backbone forward handoff** (`map-architecture → … → review-feature → ship-feature`): `/clear` mandatory + the next stage.
- **Loop-back** (`review-feature → implement-tasks` on `CHANGES REQUESTED`): **no `/clear`** — you stay in context
  to iterate; *Run next* = `/yi-sdlc:implement-tasks <slug>` (fix), then re-review the changed surface.
- **Terminal** (`ship-feature`): there is no `/yi-sdlc:` successor. *Run next* becomes **Done** — the PR command/URL
  + «merging to main is your call»; still print *What I did* + *Review* (the changelog + PR).
- **Utility** (`classify-size`, `fix-term`, `decide-adr`, `roadmap`): called ad-hoc, not a gate.
  `/clear` is **optional** (recommend it only if the context is large); *Run next* = «resume your
  backbone stage», naming the likely one (e.g. `/yi-sdlc:architecture-design <slug>`). Print *What I did* + *Review*
  (the one file it wrote).

## Canonical sequence (stage → review-files → next)

| Stage | Review before continuing (files written) | Run next |
|---|---|---|
| `map-architecture` | `docs/architecture-map.md` (+ scaffold `tasks.json` on greenfield) | `/yi-sdlc:write-prd <slug>` |
| `write-prd` | `docs/features/<slug>/PRD.md` | `/yi-sdlc:clarify-prd <slug>` |
| `clarify-prd` | `docs/features/<slug>/PRD.md` (tightened) | `/yi-sdlc:fix-term <slug>` ↳ or `/yi-sdlc:architecture-design <slug>` |
| `architecture-design` | `sad.md` (C4 §3/§5 + `target_surfaces`) + `adr/` | `/yi-sdlc:complete-sequence-diagrams <slug>` |
| `complete-sequence-diagrams` | `sad.md` §6 (flows) | `/yi-sdlc:generate-data-model <slug>` |
| `generate-data-model` | `data-model.md` + staged `migrations/` | `/yi-sdlc:api-forge <slug>` |
| `api-forge` | `contracts/openapi.yaml` (+ `events.md`, `api-sync-report.md`) | `/yi-sdlc:break-tasks <slug>` |
| `break-tasks` | `tasks/` + `tasks.json` | `/yi-sdlc:plan-tests <slug>` ↳ then `/yi-sdlc:implement-tasks <slug>` |
| `plan-tests` | `test-plan.md` (or `PRD.md` `## Test plan` for XS/S) | `/yi-sdlc:implement-tasks <slug>` |
| `implement-tasks` | the committed diff (code + tests) + `tasks/tracker.md` | `/yi-sdlc:review-feature <slug>` |
| `review-feature` | `_review/review-<date>.md` | `/yi-sdlc:ship-feature <slug>` (PASS) · `/yi-sdlc:implement-tasks <slug>` (CHANGES, no `/clear`) |
| `ship-feature` | `CHANGELOG` + the PR | **Done** — PR command/URL; merge is your call |
| `classify-size` | `.size` | resume — e.g. `/yi-sdlc:write-prd <slug>` |
| `fix-term` | `CONTEXT.md` | resume — e.g. `/yi-sdlc:architecture-design <slug>` |
| `decide-adr` | `adr/NNNN-<title>.md` | resume — `/yi-sdlc:break-tasks <slug>` or `/yi-sdlc:plan-tests <slug>` |
| `roadmap` | `docs/roadmap.md` | resume your backbone stage |

## Discipline

- **The block is the last thing printed — every run, no exceptions.** A skill that ends on prose
  without it has regressed.
- **Real paths, not descriptions.** «the SAD» is not reviewable; `docs/features/<slug>/sad.md` is.
- **The next command is copy-ready** — `/yi-sdlc:<name> <slug>` in a fenced block, slug substituted.
- **`/clear` only where it's correct** — mandatory on a forward backbone handoff, omitted on a
  loop-back (you're iterating), optional after a utility.
- **Format canonical here** — a skill that hand-rolls its own block shape has duplicated the contract.

## Where each skill calls this

Every skill's final protocol step ends with: «emit the **stage-handoff block** per
[`handoff.md`](./handoff.md)» + its own next command from the table above. The format + variants live
here; the skill supplies only the run-specific content.
