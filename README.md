# Launch Tube

A launcher for streaming services and media apps for Linux and Windows (and
maybe OS X).

## Features

  * Full screen media app launcher 
  * Pre-loaded launchers for a variety of streaming services
  * External player support for Emby and Jellyfin
  * Custom javascript to make web apps like Emby, Jellyfin, Pluto and others
    work with the launcher and as a TV-based app driven by a remote rather than
    a mouse.

I aimed at a Roku-like experience:  users launch apps from a main screen.  But
instead of Roku apps, you just launch native and web apps.

## Lots Of Launchers

  * appletv
  * navidrome
  * britbox
  * netflix
  * crackle
  * nfl
  * crunchyroll
  * paramount
  * curiosity
  * pbs
  * disney
  * peacock
  * emby
  * plex
  * espn
  * pluto-tv
  * freevee
  * prime
  * hulu
  * soundcloud
  * jellyfin
  * spotify
  * kodi
  * tubi
  * manifest
  * youtube
  * max
  * youtube-music
  * nasaplus

## Custom Javascript

I have [a tiny remote
keyboard](https://www.amazon.com/Backlit-Wireless-Keyboard-Touchpad-Rechargeable/dp/B08TM6132G)
that lets me navigate any web app.  But mousing around with it to choose a video
can be a pain, so I've started developing custom javascript layers that make it
easier to use those web apps with a tiny remote keyboard.  Launchtube manages
loading of those custom layers to make it easy.

Emby and Jellyfin play videos in the browser, but struggle with high bitrates.
Launctube's custom JS sends those video streams to mpv instead.  It then handles
the transition back and forth between your external player and your web app.

The javascript structure makes it possible to continue development of these
overlays to introduce shortcuts, arrow-key navigation, and other customizations.

## Screensaver management

If you're running xscreensaver, you can dump a bunch of photos in a directory.
And your screen saver can be a bunch of movie posters.  Launchtube will handle
disabling your screensaver while you're playing videos in mpv or web apps.

## Setup

There are many ways to set this up.  Here is how I did it.

### Guest Account

If you're setting this up as a media PC, you'll need a user account.  On Linux,
you can set this user account to automatically log in.  I chose the name "guest"
for this account:

Edit /etc/lightdm/lightdm.conf:

```
[Seat:*]
autologin-user=guest
autologin-user-timeout=0
```

### Screensaver

```
$ sudo apt install mpv xscreensaver xscreensaver-gl-extra unclutter

# Prevent rfkill warnings on wake from sleep
sudo usermod -aG netdev guest
```


As guest:
```
$ gsettings set org.gnome.desktop.screensaver lock-enabled false

# Auto-start screensaver on login
$ cat > ~/.config/autostart/xscreensaver.desktop << 'EOF'
[Desktop Entry]
Type=Application
Name=XScreenSaver
Exec=xscreensaver -nosplash
Hidden=false
EOF

# Hide the mouse when you're not using it
$ cat > ~/.config/autostart/unclutter.desktop << 'EOF'
[Desktop Entry]
Type=Application
Name=Unclutter
Exec=unclutter --timeout 3
Hidden=false
X-GNOME-Autostart-enabled=true
EOF

```

### Install greasemonkey or tampermonkey into Firefox/Chrome.

Launchtube will try to detect if you need these and prompt you to install one.
This is what enables custom javascript on a web app, whether that app is
self-hosted (like Emby) or delivered from a company like Netflix.

## Operating System

This should work on Linux or Windows or even WSL.  If you're going to run
launchtube in WSL, it's best to install mpv.exe on the Windows side.  Running
your media player from the Windows side works much better.
