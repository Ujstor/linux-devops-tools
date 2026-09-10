# specs/

Every project and every significant feature in these repositories starts with a spec, and the
spec is the durable artifact: **the code is derived from it, not the other way round.** A spec
answers *what* and *why* in measurable, technology-free terms; its plan answers *how* and is
where every technical decision, rejected alternative and environmental constraint is recorded.
When the two disagree with the code, the code wins and the plan is corrected — a plan that no
longer describes what shipped is worse than no plan, so each one carries a "where the build
diverged" section rather than being quietly left behind.

| spec | status | what it covers |
|---|---|---|
| [001-linux-devops-tools](001-linux-devops-tools/) — [spec](001-linux-devops-tools/spec.md) · [plan](001-linux-devops-tools/plan.md) | implemented | the whole repository: capturing a hand-built workstation as a description, generalising it to both supported distributions, making re-runs safe, and keeping browser-based logins working on a terminal-only machine |

001 was written and shipped while this repository still answered to an earlier name. The
directory is named for the **project**, not for the branch, so it was renamed along with the
project; the feature branch it shipped on keeps the older slug, and git history keeps both.

New spec: take the next free `NNN`, create `specs/NNN-short-name/`, write `spec.md` before any
code, then `plan.md` before any design work. Keep tooling, file layouts and commands out of the
spec — the moment one appears there, it belongs in the plan.
