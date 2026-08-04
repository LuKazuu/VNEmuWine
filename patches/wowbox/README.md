# box64 patches (wowbox64.dll)

Drop your custom box64 patches here. They will be applied to the
`ptitSeb/box64` source tree (with `patch -p1`) before building
`wowbox64.dll`.

## Naming

- `*.patch` — applied with `patch -p1` against the checked-out box64 source.

## Behavior

- If this folder is **empty** (or contains no `*.patch` files), the build
  continues without applying any patches — i.e. it builds the upstream
  box64 ref as-is.
- If any patch **fails** to apply (verified via `patch --dry-run -p1`),
  the whole workflow aborts before the build starts. Fix the patch or
  remove it before re-running.
- Patches are applied in filename-sorted order. Use a numeric prefix
  (e.g. `0100-my-fix.patch`, `0200-other.patch`) if order matters.

## Example

```bash
# Generate a patch from a local box64 checkout
cd box64
# ...edit files...
git diff > /path/to/WinHubWine/patches/wowbox/0100-my-fix.patch
```
