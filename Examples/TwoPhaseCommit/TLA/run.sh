#!/bin/sh
# Model-checks TwoPhase.tla without and with the coordinator crash. Needs a
# Java runtime and tla2tools.jar (https://github.com/tlaplus/tlaplus/releases);
# point JAVA and TLA2TOOLS at them.
set -e
cd "$(dirname "$0")"
JAVA="${JAVA:-java}"
JAR="${TLA2TOOLS:-tla2tools.jar}"
check() {  # config
  echo "== $1"
  "$JAVA" -cp "$JAR" tlc2.TLC -config "$1.cfg" -workers 1 -metadir "states/$1" TwoPhase.tla || true
}
check TwoPhase
check Crash
