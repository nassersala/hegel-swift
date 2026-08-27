#!/bin/sh
# Model-checks Quicksort.tla for N = 4 over values {0, 1, 2}. Needs a Java
# runtime and tla2tools.jar (https://github.com/tlaplus/tlaplus/releases);
# point JAVA and TLA2TOOLS at them.
set -e
cd "$(dirname "$0")"
"${JAVA:-java}" -cp "${TLA2TOOLS:-tla2tools.jar}" tlc2.TLC -config Quicksort.cfg -workers 1 -deadlock -metadir states Quicksort.tla
