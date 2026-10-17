#!/usr/bin/env bash
# Builds the app for the browser into out/. Then serve it and open it:
#
#   ./build.sh
#   cd out && python3 -m http.server 8765      # then http://localhost:8765 in Firefox
set -e
cd "$(dirname "$0")"
source ~/dlang/ldc-1.43.0/activate
source ~/emsdk/emsdk_env.sh > /dev/null 2>&1
../mayfair/web/build.sh -o out -J views source/app.d
