#!/bin/sh
# Model-checks the TLA twins. Auth.tla for N = 3, G = 2: the bounded
# relation (all properties hold), the unbounded one (Inv and liveness
# still hold), and the unbounded one against the trace property
# (violated: the loop). Deploy.tla: the two refuted designs (ZeroDowntime
# in two steps, SameVersion in two steps), the relation for N = 5, K = 2
# (all invariants and liveness hold), and N = 3, K = 2 (deadlock: three
# servers cannot keep two online).
# Needs a Java runtime and tla2tools.jar
# (https://github.com/tlaplus/tlaplus/releases); point JAVA and TLA2TOOLS
# at them.
set -e
cd "$(dirname "$0")"
JAVA="${JAVA:-java}"
JAR="${TLA2TOOLS:-tla2tools.jar}"
check() {  # module config [flags]
  echo "== $2"
  "$JAVA" -cp "$JAR" tlc2.TLC -config "$2.cfg" -workers 1 $3 -metadir "states/$2" "$1.tla" || true
}
check Auth Auth -deadlock
check Auth Unbounded -deadlock
check Auth UnboundedLoop -deadlock
check Deploy DeployAny
check Deploy DeployOne
check Deploy DeployBalanced
check Deploy DeployThreeForTwo
