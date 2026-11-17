# Ubuntu 24.04's real desktop shell, headless: GNOME Shell on Wayland with a
# virtual monitor and XWayland, the setup a stock Ubuntu laptop runs. The
# plain Xvfb box has no top bar and no GNOME window rules, so it cannot show
# problems like the card hiding behind GNOME's panel.
FROM ubuntu:24.04
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
        gnome-shell gnome-shell-extension-appindicator xwayland dbus dbus-x11 \
        python3 python3-gi python3-gi-cairo gir1.2-gtk-3.0 gir1.2-ayatanaappindicator3-0.1 \
        libnotify-bin curl ca-certificates fonts-dejavu-core fonts-ubuntu yaru-theme-gtk yaru-theme-icon \
        x11-utils xdotool imagemagick dpkg-dev \
    && rm -rf /var/lib/apt/lists/*
RUN mkdir -m 1777 /tmp/.X11-unix && useradd -m -s /bin/bash tester
USER tester
WORKDIR /home/tester/app
