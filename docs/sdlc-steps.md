# yi-sdlc steps

yi-sdlc has three ticket routes, all ending in a merged PR. Which one a ticket takes depends on its size.

| Ticket | Route |
|---|---|
| Defect: restore behaviour the docs already promise | `/yi-sdlc:implement-fix <id>` |
| Change to an existing feature that fits one PR | `/yi-sdlc:implement-change <id>` |
| New feature, or a change too big for one PR | `/yi-sdlc:implement-feature <id>`: the full pipeline below |

## Full SDLC pipeline (`implement-feature`)

| # | Stage | Skill | Done when |
|---|---|---|---|
| 1 | Ideation | `yi-sdlc:interview` | `idea-brief.md` has `status: Confirmed` |
| 2 | PRD | `yi-sdlc:write-prd` | `PRD.md` and `.size` exist |
| 3 | Clarify | `yi-sdlc:clarify-prd` | Every ambiguity is resolved, or is in §8 with an owner |
| — | **Gate 1: PRD approval** | | |
| 4 | Architecture | `yi-sdlc:architecture-design` | `sad.md` is finalized and its ADRs are Accepted |
| 5 | Sequences | `yi-sdlc:complete-sequence-diagrams` | `sad.md` §6 has flows covering the ACs |
| — | **Gate 2: architecture approval** | | |
| 6 | Data model | `yi-sdlc:generate-data-model` | `data-model.md` and staged migrations exist (skipped if nothing new is stored) |
| 7 | API contract | `yi-sdlc:api-forge` | `contracts/openapi.yaml` exists (skipped if no endpoint changes) |
| 8 | Design spec | `yi-sdlc:prepare-design-spec` | `design-spec.md` exists (web surfaces only) |
| 9 | Tasks | `yi-sdlc:break-tasks` | `tasks/tasks.json` exists |
| 10 | Test plan | `yi-sdlc:plan-tests` | `test-plan.md` exists |
| — | **Gate 3: plan approval, before any code** | | |
| 11 | Implementation | `yi-sdlc:implement-tasks` | Every task is done, written test-first |
| 12 | Review | `yi-sdlc:review-feature` | The review shows PASS |
| 13 | Live check | `yi-sdlc:verify-ui` (web) | It works on the isolated app |
| 14 | Ship | `yi-sdlc:ship-feature` | Changelog, PR body, roadmap shows Shipped |

The PR is then opened, the ticket is updated, and the merge waits for the operator's approval.

## One-PR change (`implement-change`)

0. Get the issue ID.
1. Read the ticket: check its column, check it's a change, read its `sdlc-mode`, find the feature it
   belongs to, and split it into items.
2. Check it fits one PR. If it doesn't, it moves to the full pipeline.
3. Bring up the isolated environment.
4. Record how each item behaves today.
5. Write the acceptance criteria into the PRD, then run the ambiguity check (`yi-sdlc:devils-advocate`).
6. **Stop: the operator approves the acceptance criteria.**
7. Write the failing tests first.
8. Implement, then bring the docs in line with the code.
9. Run the gates.
10. Review (`yi-sdlc:reviewer`).
11. Show it working on the running app, before and after.
12. Add an entry to the feature changelog.
13. Decide whether manual testing is needed.
14. Open the PR and update the ticket.
15. **Stop: the operator approves the merge.**
16. Merge, move the ticket, and take down the environment.

## SDLC mode

The ticket's `sdlc-mode` sets how many of those stops happen:

| `sdlc-mode` | Behaviour |
|---|---|
| `auto` | No stops; it merges by itself. Stops only on critical issues |
| `semi-auto` | Both stops |
| `developer` (default when nothing is set) | A brief, then a working session with the operator |

## Standalone helpers, usable anytime

| Skill | Use |
|---|---|
| `yi-sdlc:fix-term` | Add or update a glossary term in `CONTEXT.md` |
| `yi-sdlc:decide-adr` | Record an architecture decision after the fact |
| `yi-sdlc:classify-size` | Classify a feature as XS–XL |
| `yi-sdlc:map-architecture` | Map an existing codebase's architecture |
| `yi-sdlc:roadmap` | Maintain `docs/roadmap.md` |
| `yi-sdlc:user-documentation` | Write user docs by walking the app's flows |
| `yi-sdlc:run-application` | Run the app from any worktree, on its own ports |
| `yi-sdlc:create-tickets` | File roadmap steps as tracker tickets (Epic, Feature or Task by size), linked by the roadmap's dependencies |
| `yi-sdlc:process-tickets` | Rank the board's ready tickets and start the picks in Pane, a feature per Pane running `implement-feature` |
