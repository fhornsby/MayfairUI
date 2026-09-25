#!/usr/bin/env sh
#
# Checks Mayfair's widgets as a screen reader sees them, over AT-SPI. Linux only.
#
# AccessKit only answers while the session's accessibility is on, so this switches it on for the
# run -- the same as toggling GNOME's toolkit-accessibility setting -- and puts it back how it was
# afterwards, whatever happens. That's why it isn't part of `dub run`: it changes a desktop
# setting while it runs.
#
#   tests/accessibility/run.sh
set -eu
cd "$(dirname "$0")/.."

dub build -q

was=$(busctl --user get-property org.a11y.Bus /org/a11y/bus org.a11y.Status IsEnabled | awk '{print $2}')
restore() { busctl --user set-property org.a11y.Bus /org/a11y/bus org.a11y.Status IsEnabled b "$was"; }
trap restore EXIT INT TERM
busctl --user set-property org.a11y.Bus /org/a11y/bus org.a11y.Status IsEnabled b true

./mayfair-tests --accessibility-app &
app=$!
sleep 3
status=0
python3 accessibility/check.py || status=$?
kill "$app"
wait "$app" 2>/dev/null || true
exit $status
