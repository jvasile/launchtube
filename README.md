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
$ sudo apt install caffeine mpv xscreensaver xscreensaver-gl-extra unclutter

# Prevent rfkill warnings on wake from sleep
sudo usermod -aG netdev guest
```

Let's try to do slidehow without xscreensaver.  We'll use glslideshow, which is
in the xscreensaver-gl package.

```
$ sudo apt install xscreensaver-gl xss-lock
```

As guest:
```
$ gsettings set org.gnome.desktop.screensaver lock-enabled false

# Add to ~/.config/mpv/mpv.conf
stop-screensaver=always

# Auto-start on login - create ~/.config/autostart/xscreensaver.desktop:
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

# Create ~/.config/autostart/unclutter.desktop:
[Desktop Entry]
Type=Application
Name=Unclutter
Exec=unclutter --timeout 3
Hidden=false
X-GNOME-Autostart-enabled=true


```


Install greasemonkey or tampermonkey into Firefox/Chrome.


# OS

This should work on Linux or Windows or even WSL.  If you're going to run
launchtube in WSL, it's best to install mpv.exe on the Windows side.  Running
your media player from the Windows side works much better.
