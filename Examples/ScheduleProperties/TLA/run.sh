#!/bin/sh
# Model-checks Bank.tla (three configurations) and Transfer.tla. Needs a
# Java runtime and tla2tools.jar (https://github.com/tlaplus/tlaplus/releases);
# point JAVA and TLA2TOOLS at them.
set -e
cd "$(dirname "$0")"
JAVA="${JAVA:-java}"
JAR="${TLA2TOOLS:-tla2tools.jar}"
check() {  # module config
  echo "== $2"
  "$JAVA" -cp "$JAR" tlc2.TLC -config "$2.cfg" -workers 1 -deadlock -metadir "states/$2" "$1.tla" || true
}
check Bank Unsafe
check Bank UnsafeMechanism
check Bank Safe
check Transfer Transfer
