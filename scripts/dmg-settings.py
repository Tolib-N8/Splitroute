# Оформление DMG для dmgbuild: тёмный фон с потоками частиц, иконка приложения и ярлык «Программы».
import os

app = defines["app"]
files = [app]
symlinks = {"Applications": "/Applications"}
icon = os.path.join(app, "Contents/Resources/AppIcon.icns")
background = defines["background"]
format = "ULFO"
filesystem = "HFS+"

window_rect = ((200, 140), (660, 448))  # 420 содержимого + заголовок окна
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
icon_size = 112
text_size = 13
hide_extensions = [os.path.basename(app)]
icon_locations = {
    os.path.basename(app): (170, 210),
    "Applications": (490, 210),
}
