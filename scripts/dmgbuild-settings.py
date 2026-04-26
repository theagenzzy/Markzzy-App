# dmgbuild settings for the Markzzy installer DMG.
#
# Why dmgbuild instead of `create-dmg`?
#   `create-dmg` (the Homebrew bash wrapper) drops a .DS_Store with
#   `backgroundColorRed/Green/Blue = 1.0` (pure white) regardless of the
#   actual background image. Finder reads those RGB values to decide the
#   label-text color: light bg → dark text. With our dark-navy background
#   image, Finder would still paint dark labels because the *color* field
#   (not the image) drives that choice.
#   `dmgbuild` (Python) gives us programmatic control over the .DS_Store,
#   so we can override `backgroundColor*` to navy → Finder picks WHITE
#   labels automatically. That's the proper fix for the dark-on-dark bug.
#
# Invoked from `scripts/build-dmg-local.sh` and `.github/workflows/release.yml`:
#   dmgbuild -s scripts/dmgbuild-settings.py \
#            -D app=/path/to/Markzzy.app \
#            -D background=Resources/dmg-background.png \
#            "<volume name>" "<out>.dmg"

import os.path

# `defines` is injected by dmgbuild from -D arguments on the CLI.
defines = globals().get("defines", {})  # type: ignore[name-defined]

application = defines.get("app", os.path.expanduser("~/Desktop/Markzzy.app"))
appname = os.path.basename(application)
background_path = defines.get("background", "Resources/dmg-background.png")

# ---- Volume layout ---------------------------------------------------------

# UDZO = compressed read-only, the format notarytool expects.
format = "UDZO"

# Files placed at the mount root. /Applications shortcut comes from
# `symlinks` so users can drag-to-install.
files = [application]
symlinks = {"Applications": "/Applications"}

# Hide ".app" extension in Finder, matching OBS / Notion / Slack polish.
hide_extension = [appname]

# ---- Window + icon placement ----------------------------------------------
# Mirrors the create-dmg invocation we used to ship, so existing visual
# layout is preserved exactly.
background = background_path
window_rect = ((200, 120), (600, 400))   # ((x, y), (w, h))
icon_size = 128
text_size = 14   # was 13 — slightly bigger reads better on the dark bg

icon_locations = {
    appname: (150, 200),
    "Applications": (450, 200),
}

default_view = "icon-view"
show_icon_preview = False
show_item_info = False
include_icon_view_settings = "auto"
include_list_view_settings = "auto"
arrange_by = None
grid_offset = (0, 0)
label_pos = "bottom"

license = None

# ---- THE FIX: monkey-patch icvp -------------------------------------------
#
# dmgbuild hardcodes `backgroundColorRed/Green/Blue = 1.0` (white) when a
# background IMAGE is supplied — there's no public setting to override it.
# We wrap the `__setitem__` on ds_store's partial dict so that when
# dmgbuild writes the icvp blob, we inject our dark-navy color into the
# same dict. Finder then reads dark-navy as the bg color → switches label
# text to white automatically. No private icvp keys needed; just the
# ones Finder already documents.

import ds_store.store as _ds_store_module

_real_setitem = _ds_store_module.DSStore.Partial.__setitem__

# Match the navy gradient midpoint of generate-dmg-background.swift —
# top is #121F45, bottom is #060D1F. Average ≈ #0C1632. Storing that as
# 0..1 floats so Finder's contrast check sees a dark background.
_NAVY = (0.04, 0.08, 0.20)  # ≈ #0A1433


def _patched_setitem(self, code, value):  # noqa: ANN001
    if code == b"icvp" or code == "icvp":
        if isinstance(value, dict):
            value = dict(value)
            value["backgroundColorRed"] = _NAVY[0]
            value["backgroundColorGreen"] = _NAVY[1]
            value["backgroundColorBlue"] = _NAVY[2]
    return _real_setitem(self, code, value)


_ds_store_module.DSStore.Partial.__setitem__ = _patched_setitem
