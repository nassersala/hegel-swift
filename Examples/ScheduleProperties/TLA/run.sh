#!/bin/sh
# Model-checks Bank.tla both ways. Needs a Java runtime and tla2tools.jar
# (https://github.com/tlaplus/tlaplus/releases); point TLA2TOOLS at the jar.
set -e
cd "$(dirname "$0")"
JAVA="${JAVA:-java}"
JAR="${TLA2TOOLS:-tla2tools.jar}"
for cfg in Unsafe UnsafeMechanism Safe; do
  echo "== $cfg"
  "$JAVA" -cp "$JAR" tlc2.TLC -config "$cfg.cfg" -workers 1 -deadlock -metadir "states/$cfg" Bank.tla || true
done
