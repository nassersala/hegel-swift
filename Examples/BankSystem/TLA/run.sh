#!/bin/sh
# Model-checks BankSystem.tla: the composed relation under fairness of the
# tellers' timers and of the network (every invariant and both liveness
# properties hold), under fairness of the timers alone (liveness still
# holds: P4b makes it the teller's own), and the stronger liveness "an
# applied request's teller learns the reply itself" (violated: the reply
# of a given-up request is ignored, the Late clause of the verdict list).
# Needs a Java runtime and tla2tools.jar; point JAVA and TLA2TOOLS at them.
set -e
cd "$(dirname "$0")"
JAVA="${JAVA:-java}"
JAR="${TLA2TOOLS:-tla2tools.jar}"
check() {  # config
  echo "== $1"
  "$JAVA" -XX:+UseParallelGC -cp "$JAR" tlc2.TLC -config "$1.cfg" -workers auto -metadir "states/$1" BankSystem.tla || true
}
check BankSystem
check UnfairNet
check Learned
