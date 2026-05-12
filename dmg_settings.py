import os.path

application = 'Wattmeter.app'
appname = os.path.basename(application)

format = 'UDZO'
size = '50M'
files = [application]
symlinks = {'Applications': '/Applications'}

icon_locations = {
    appname: (195, 270),
    'Applications': (515, 270),
}

background = 'dmg_bg.png'
window_rect = ((200, 120), (720, 480))
default_view = 'icon-view'
icon_size = 128
text_size = 14

icon_view_settings = {
    'arrangement': 'none',
    'icon_size': 128,
    'text_size': 14,
    'label_position': 'bottom',
    'show_item_info': False,
    'show_icon_preview': False,
    'background_picture': 'dmg_bg.png',
}

include_icon_view_settings = 'auto'
include_list_view_settings = 'auto'
