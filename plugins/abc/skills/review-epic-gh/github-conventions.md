# GitHub conventions (re-export)

Canonical copy: [`../scaffold-sub-issues-gh/github-conventions.md`](../scaffold-sub-issues-gh/github-conventions.md) — the label scheme, task-list fence, and marker-comment formats shared across the `-gh` skill family. Read that file; do not duplicate its content here.

`review-epic-gh` writes one additional marker namespace, **shared with its Linear sibling `review-epic`** (both variants write the identical `review-epic:reviewed-at:<sha>` marker — the namespace is owned by the review-epic *pair*, not by the `-gh` variant alone), scoped alongside the family's existing ones:

| Marker | Posted on | Meaning |
|---|---|---|
| `<!-- review-epic:reviewed-at:<sha> -->` | child PR (top-level comment, marker-only body) | This loop reviewed the PR at HEAD `<sha>`; skip until a new commit lands. Written by both `review-epic` (Linear) and `review-epic-gh` (GitHub). |
