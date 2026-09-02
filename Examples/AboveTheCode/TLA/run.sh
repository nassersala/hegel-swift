#!/bin/sh
# Model-checks Auth.tla for N = 3, G = 2: the bounded relation (all
# properties hold), the unbounded one (Inv and liveness still hold), and
# the unbounded one against the trace property (violated: the loop).
# Needs a Java runtime and tla2tools.jar
# (https://github.com/tlaplus/tlaplus/releases); point JAVA and TLA2TOOLS
# at them.
set -e
cd "$(dirname "$0")"
JAVA="${JAVA:-java}"
JAR="${TLA2TOOLS:-tla2tools.jar}"
check() {  # config
  echo "== $1"
  "$JAVA" -cp "$JAR" tlc2.TLC -config "$1.cfg" -workers 1 -deadlock -metadir "states/$1" Auth.tla || true
}
check Auth
check Unbounded
check UnboundedLoop
