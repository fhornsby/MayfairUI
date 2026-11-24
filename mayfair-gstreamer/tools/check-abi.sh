#!/usr/bin/env sh
# Checks gst.d's hand-written GStreamer declarations against the installed GStreamer's headers
# (needs its development package: libgstreamer1.0-dev and libgstreamer-plugins-base1.0-dev).
set -eu
cd "$(dirname "$0")"
cc $(pkg-config --cflags gstreamer-1.0 gstreamer-app-1.0) -fsyntax-only check-abi.c
echo "gst.d matches GStreamer $(pkg-config --modversion gstreamer-1.0)"
