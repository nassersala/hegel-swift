// Differential-conformance harness: the hegel-go mirror of
// ../transcript-swift. Same seed, same settings, same draw sequence with
// identical arguments — the transcripts must match byte for byte. One
// program per invocation: `transcript-go <program>`; an unknown name
// exits 2.
package main

import (
	"fmt"
	"math"
	"os"
	"strings"

	"hegel.dev/go/hegel"
)

func options(cases int) []hegel.Option {
	return []hegel.Option{
		hegel.WithTestCases(cases),
		hegel.WithSeed(42),
		hegel.WithDerandomize(true),
		hegel.WithDatabase(""),
		hegel.WithVerbosity(hegel.VerbosityQuiet),
		hegel.WithStatefulStepCount(6),
	}
}

func run(cases int, fn func(tc hegel.TestCase)) {
	if err := hegel.Run(fn, options(cases)...); err != nil {
		panic(err)
	}
}

func list[T any](xs []T) string {
	parts := make([]string, len(xs))
	for i, x := range xs {
		parts[i] = fmt.Sprint(x)
	}
	return "[" + strings.Join(parts, ",") + "]"
}

func primitives() {
	run(32, func(tc hegel.TestCase) {
		a := hegel.Draw(tc, hegel.Integers(int64(0), int64(1000)))
		b := hegel.Draw(tc, hegel.Integers(int64(math.MinInt64), int64(math.MaxInt64)))
		c := hegel.Draw(tc, hegel.Booleans())
		d := hegel.Draw(tc, hegel.Floats[float64]().Min(0).Max(1))
		e := hegel.Draw(tc, hegel.Binary(0, 16))
		fmt.Printf("case a=%d b=%d c=%t d=%016x e=%x\n", a, b, c, math.Float64bits(d), e)
	})
}

func bigints() {
	run(32, func(tc hegel.TestCase) {
		f := hegel.Draw(tc, hegel.Integers(uint64(0), uint64(math.MaxUint64)))
		fmt.Printf("case f=%d\n", f)
	})
}

func text() {
	run(32, func(tc hegel.TestCase) {
		t := hegel.Draw(tc, hegel.Text().MaxSize(8))
		fmt.Printf("case t=%x\n", t)
	})
}

func stringsProgram() {
	run(32, func(tc hegel.TestCase) {
		a := hegel.Draw(tc, hegel.Text().MaxSize(8).Codec("ascii"))
		r := hegel.Draw(tc, hegel.FromRegex("[a-z]{1,4}", true))
		e := hegel.Draw(tc, hegel.Emails())
		fmt.Printf("case a=%x r=%x e=%x\n", a, r, e)
	})
}

func lists() {
	run(32, func(tc hegel.TestCase) {
		l := hegel.Draw(tc, hegel.Lists(hegel.Integers(int64(0), int64(9))).MaxSize(4))
		m := hegel.Draw(tc, hegel.Lists(hegel.Booleans()).MinSize(1).MaxSize(3))
		fmt.Printf("case l=%s m=%s\n", list(l), list(m))
	})
}

// Counter is the state machine; reject gives RuleReset an assumption so a
// selected rule can be rejected.
type Counter struct {
	n      int64
	reject bool
}

func (m *Counter) RuleAdd(tc hegel.TestCase) {
	k := hegel.Draw(tc, hegel.Integers(int64(1), int64(9)))
	m.n += k
	fmt.Printf("step add %d -> %d\n", k, m.n)
}

func (m *Counter) RuleReset(tc hegel.TestCase) {
	if m.reject && m.n == 0 {
		fmt.Println("step reset rejected")
		tc.Assume(false)
	}
	m.n = 0
	fmt.Println("step reset -> 0")
}

func (m *Counter) InvariantNonNeg(tc hegel.TestCase) {
	if m.n < 0 {
		panic("negative")
	}
}

func stateful(reject bool) {
	run(8, func(tc hegel.TestCase) {
		fmt.Println("case")
		hegel.RunStateful(tc, &Counter{reject: reject})
	})
}

func main() {
	program := ""
	if len(os.Args) > 1 {
		program = os.Args[1]
	}
	switch program {
	case "primitives":
		primitives()
	case "bigints":
		bigints()
	case "text":
		text()
	case "strings":
		stringsProgram()
	case "lists":
		lists()
	case "stateful":
		stateful(false)
	case "stateful-reject":
		stateful(true)
	default:
		fmt.Fprintf(os.Stderr, "transcript-go: no program named %q\n", program)
		os.Exit(2)
	}
}
