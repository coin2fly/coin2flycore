
Debian
====================
This directory contains files used to package coin2flyd/coin2fly-qt
for Debian-based Linux systems. If you compile coin2flyd/coin2fly-qt yourself, there are some useful files here.

## coin2fly: URI support ##


coin2fly-qt.desktop  (Gnome / Open Desktop)
To install:

	sudo desktop-file-install coin2fly-qt.desktop
	sudo update-desktop-database

If you build yourself, you will either need to modify the paths in
the .desktop file or copy or symlink your coin2fly-qt binary to `/usr/bin`
and the `../../share/pixmaps/coin2fly128.png` to `/usr/share/pixmaps`

coin2fly-qt.protocol (KDE)

