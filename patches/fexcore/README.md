# FEX patches (libarm64ecfex.dll + libwow64fex.dll)

Drop your custom FEX patches here. They will be applied to the
`FEX-Emu/FEX` source tree (with `patch -p1`) before building
`libarm64ecfex.dll` and `libwow64fex.dll`.

## Naming

- `*.patch` — applied with `patch -p1` against the checked-out FEX source.

## Behavior

- If this folder is **empty** (or contains no `*.patch` files), the build
  continues without applying any patches — i.e. it builds the upstream
  FEX ref as-is.
- If any patch **fails** to apply (verified via `patch --dry-run -p1`),
  the whole workflow aborts before the build starts. Fix the patch or
  remove it before re-running.
- Patches are applied in filename-sorted order. Use a numeric prefix
  (e.g. `0100-my-fix.patch`, `0200-other.patch`) if order matters.

## Example

```bash
# Generate a patch from a local FEX checkout
cd fex
# ...edit files...
git diff > /path/to/WinHubWine/patches/fexcore/0100-my-fix.patch
```
