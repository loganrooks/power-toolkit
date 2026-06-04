#!/bin/zsh
# Bootstrap: install deps (if brew present), then hand off to `pm install`.
emulate -L zsh
HERE=${0:A:h}
chmod +x "$HERE/bin/pm" "$HERE"/libexec/*(.) 2>/dev/null
if command -v brew >/dev/null; then
  for t in blueutil sleepwatcher; do
    command -v $t >/dev/null || brew install $t
  done
fi
exec "$HERE/bin/pm" install
