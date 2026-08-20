// Differential-conformance harness: the hegel-go mirror of
// ../transcript-swift. Same seed, same settings, same draw sequence with
// identical arguments — the transcripts must match byte for byte.
package main

import (
	"fmt"
	"math"

	"hegel.dev/go/hegel"
)

func main() {
	err := hegel.Run(func(tc hegel.TestCase) {
		a := hegel.Draw(tc, hegel.Integers(int64(0), int64(1000)))
		b := hegel.Draw(tc, hegel.Integers(int64(math.MinInt64), int64(math.MaxInt64)))
		c := hegel.Draw(tc, hegel.Booleans())
		d := hegel.Draw(tc, hegel.Floats[float64]().Min(0).Max(1))
		e := hegel.Draw(tc, hegel.Binary(0, 16))
		fmt.Printf("case a=%d b=%d c=%t d=%016x e=%x\n", a, b, c, math.Float64bits(d), e)
	},
		hegel.WithTestCases(32),
		hegel.WithSeed(42),
		hegel.WithDerandomize(true),
		hegel.WithDatabase(""),
		hegel.WithVerbosity(hegel.VerbosityQuiet),
	)
	if err != nil {
		panic(err)
	}
}
