# Launch Tube

A launcher for streaming services and media apps.

## Setup

Edit /etc/lightdm/lightdm.conf:

```
[Seat:*]
autologin-user=guest
autologin-user-timeout=0
```

```
$ sudo apt install caffeine xscreensaver xscreensaver-gl-extra
```

As guest:
```
$ gsettings set org.gnome.desktop.screensaver lock-enabled false

# 4. Auto-start on login - create ~/.config/autostart/xscreensaver.desktop:
  [Desktop Entry]
  Type=Application
  Name=XScreenSaver
  Exec=xscreensaver -nosplash
  Hidden=false

# Create ~/.config/autostart/caffeine.desktop:
  [Desktop Entry]
  Type=Application
  Name=Caffeine
  Exec=caffeine-indicator
  Hidden=false
  X-GNOME-Autostart-enabled=true
```



