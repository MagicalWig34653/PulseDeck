# dmgbuild settings for the PulseDeck disk image.
# Invoked by scripts/build-dmg.sh with -D app=<path to .app> -D background=<tiff>.
# Icon positions must match packaging/dmg/render-background.swift.
import os.path

app = defines["app"]
app_name = os.path.basename(app)

format = "UDZO"
filesystem = "HFS+"
files = [app]
symlinks = {"Applications": "/Applications"}

volume_icon = os.path.join(app, "Contents", "Resources", "AppIcon.icns")
if os.path.exists(volume_icon):
    icon = volume_icon

background = defines["background"]
window_rect = ((200, 160), (660, 400))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False

icon_size = 128
text_size = 13
arrange_by = None
icon_locations = {
    app_name: (170, 185),
    "Applications": (490, 185),
}
