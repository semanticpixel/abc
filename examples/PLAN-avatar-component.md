# PLAN: Add Avatar primitive and wire it into the app header

**Status:** Draft
**Created:** 2026-05-19
**Owner:**

## Context

The app header currently shows the logged-in user as a plain name string. In multi-account flows (admin impersonation, role switching), the name alone is easy to misread, and support has flagged it as a recurring source of "wrong account" mistakes. The design system has slots reserved for an Avatar primitive but the component itself doesn't exist yet — every product team that has wanted one has rolled a one-off.

## Approach

Add a typed `<Avatar />` primitive to the `design-system` package: accepts a user object, falls back to initials when no image, supports the standard size scale, uses existing color tokens. Bump `design-system` in the consumer (`web-app`) and replace the header's name-only display with `<Avatar />` + the existing name. UI verification gates the consumer-side merge.

## Sub-tasks

> Each sub-task becomes a sub-issue via `/abc:scaffold-sub-issues` (Linear) or `/abc:scaffold-sub-issues-gh` (GitHub).
> `repo:` matches the `repo:<name>` label convention.
> `blocks` / `blocked by` create the dependency graph for `/abc:ship-epic[-gh]`.
> ST-3 carries a `validation:` bullet — its merge gates on the manual check below.

### ST-1: Add Avatar primitive to design-system

- **repo:** design-system
- **scope:** New `<Avatar />` under `src/primitives/Avatar/`. Props: `user: { name: string; imageUrl?: string }`, `size: 'sm' | 'md' | 'lg'` (default `md`). Renders an image when `imageUrl` is set; otherwise renders initials over a background from the existing `--color-surface-*` token scale. Export `AvatarProps`. Add a Storybook story under `Primitives/Avatar`.
- **acceptance criteria:**
  - Renders image when `imageUrl` is provided
  - Renders initials (first letter of each word in `user.name`, max 2) when `imageUrl` is missing
  - All three sizes pass the existing visual regression suite
  - `AvatarProps` exported from the package barrel
  - Storybook story covers both image and initials variants across all three sizes
- **blocks:** ST-3
- **blocked by:** (none)

### ST-2: Bump design-system in web-app

- **repo:** web-app
- **scope:** Update `package.json` to pin the design-system version that ships ST-1. Run typecheck + the existing test suite to catch any incidental breakage from peer-dep drift. No other dependency changes in this sub-task.
- **acceptance criteria:**
  - Lockfile updated, no unrelated dependency drift in the diff
  - `pnpm typecheck` passes
  - `pnpm test` passes
- **blocks:** ST-3
- **blocked by:** ST-1

### ST-3: Replace header name with Avatar + name

- **repo:** web-app
- **scope:** In `src/components/AppHeader/`, replace `<span>{user.name}</span>` with `<Avatar user={user} size="sm" />` followed by the name string. Preserve the existing spacing token between header elements. Update the header snapshot test and the Storybook story.
- **acceptance criteria:**
  - Avatar renders to the inline-start of the name
  - Existing header accessibility tests still pass (focus order, screen-reader labels)
  - Header snapshot test updated
  - Storybook story shows both image and initials states
- **validation:** Pull the merged branch, run `pnpm dev`, and log in as (a) a user with `imageUrl` set and (b) one without — confirm the image and initials variants both render and the header focus order is unchanged. (Attaches the post-merge `blocked-verify` gate to this child.)
- **blocks:** (none)
- **blocked by:** ST-1, ST-2

## Open questions

- Initials fallback: should background color be derived from `user.name` (stable hash) or always the same neutral token? Stable-hash is friendlier visually but adds determinism work. **Default: same neutral token; revisit if design pushes back.**
- Do we need a `loading` state for slow image fetches? **Default: no — render initials immediately, swap to image when it resolves.**

## Validation

- Pull the merged branch, run `pnpm dev`, and log in as: (a) a user with `imageUrl` set, (b) a user without. Confirm the image variant shows the photo and the initials variant shows the two-letter fallback.
- Tab through the header and verify the focus order is unchanged from before.
- Watch for layout shift (CLS) on first paint — the avatar slot should reserve space so the name doesn't jump when the image loads.

## Out of scope

- Avatar in any surface besides the app header (settings page, comment threads, mentions). Each is its own plan.
- Image upload UI — `imageUrl` is read-only for this iteration.
- Group / stacked avatars.
- Server-side initials generation — derived on the client from `user.name`.
