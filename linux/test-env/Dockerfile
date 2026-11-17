# A Linux desktop in a box for testing ClaudeNotch without a Linux machine.
#
# Ubuntu 24.04 with GTK 3 through PyGObject (what the app runs on), Xvfb as a
# virtual display, Openbox as a real window manager (keep-above and focus
# behave as they would on a desktop), xdotool to click and type, and
# ImageMagick to screenshot. curl fires hook payloads at the app the way
# Claude Code does.
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
        python3 python3-gi python3-gi-cairo gir1.2-gtk-3.0 \
        xvfb openbox xdotool imagemagick x11-utils x11-xserver-utils \
        fonts-dejavu-core fonts-noto-color-emoji \
        curl ca-certificates dbus-x11 libnotify-bin \
        dpkg-dev \
    && rm -rf /var/lib/apt/lists/*

# A normal user, so paths and permissions look like a real install.
RUN useradd -m -s /bin/bash tester
USER tester
WORKDIR /home/tester/app
