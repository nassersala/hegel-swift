/* Differential-conformance harness: the dialectic mirror of
 * ../transcript-swift, ../transcript-go and ../transcript-rust. Same
 * seed, same settings, same draw sequence with identical arguments —
 * the transcripts must match byte for byte. One program per invocation:
 * `transcript-dialectic <program>`; a program dialectic's API cannot
 * express (bigints, strings) exits 2 and the script skips the column. */

#include <dialectic.h>

#include <inttypes.h>
#include <stdio.h>
#include <string.h>

static void print_hex(const uint8_t *data, size_t length)
{
    size_t i;
    for (i = 0; i < length; i++) printf("%02x", data[i]);
}

static HegelCaseResult primitives(HegelCase *tc, void *userData)
{
    int64_t a;
    int64_t b;
    bool c;
    double d;
    HegelBytes e;
    uint64_t bits;

    (void)userData;
    HEGEL_TRY(tc, HegelDrawInteger(tc, 0, 1000, &a));
    HEGEL_TRY(tc, HegelDrawInteger(tc, INT64_MIN, INT64_MAX, &b));
    HEGEL_TRY(tc, HegelDrawBoolean(tc, 0.5, &c));
    HEGEL_TRY(tc, HegelDrawReal(tc, 0.0, 1.0, &d));
    HEGEL_TRY(tc, HegelDrawBytes(tc, 0, 16, &e));

    memcpy(&bits, &d, sizeof bits);
    printf("case a=%" PRId64 " b=%" PRId64 " c=%s d=%016" PRIx64 " e=",
           a, b, c ? "true" : "false", bits);
    print_hex(e.data, e.length);
    printf("\n");
    return HEGEL_CASE_PASS;
}

static HegelCaseResult text(HegelCase *tc, void *userData)
{
    HegelString t;

    (void)userData;
    HEGEL_TRY(tc, HegelDrawText(tc, 0, 8, &t));
    printf("case t=");
    print_hex((const uint8_t *)t.data, t.length);
    printf("\n");
    return HEGEL_CASE_PASS;
}

static HegelFlow draw_digit(HegelCase *tc, void *out, void *userData)
{
    (void)userData;
    return HegelDrawInteger(tc, 0, 9, (int64_t *)out);
}

static HegelFlow draw_bool(HegelCase *tc, void *out, void *userData)
{
    (void)userData;
    return HegelDrawBoolean(tc, 0.5, (bool *)out);
}

static HegelCaseResult lists(HegelCase *tc, void *userData)
{
    HegelArrayOptions digits = {0};
    HegelArrayOptions bools = {0};
    HegelSlice l;
    HegelSlice m;
    size_t i;

    (void)userData;
    digits.elementSize = sizeof(int64_t);
    digits.minCount = 0;
    digits.maxCount = 4;
    digits.drawElement = draw_digit;
    bools.elementSize = sizeof(bool);
    bools.minCount = 1;
    bools.maxCount = 3;
    bools.drawElement = draw_bool;
    HEGEL_TRY(tc, HegelDrawArray(tc, &digits, &l));
    HEGEL_TRY(tc, HegelDrawArray(tc, &bools, &m));

    printf("case l=[");
    for (i = 0; i < l.count; i++) {
        const int64_t *x = (const int64_t *)((const char *)l.data + i * l.stride);
        printf("%s%" PRId64, i ? "," : "", *x);
    }
    printf("] m=[");
    for (i = 0; i < m.count; i++) {
        const bool *x = (const bool *)((const char *)m.data + i * m.stride);
        printf("%s%s", i ? "," : "", *x ? "true" : "false");
    }
    printf("]\n");
    return HEGEL_CASE_PASS;
}

/* The counter under the state-machine API. The reject variant gives
 * reset a precondition, so a selected rule can be reported rejected. */
typedef struct Counter {
    int64_t n;
} Counter;

static HegelCaseResult rule_add(HegelCase *tc, void *state, void *userData)
{
    Counter *m = state;
    int64_t k;

    (void)userData;
    HEGEL_TRY(tc, HegelDrawInteger(tc, 1, 9, &k));
    m->n += k;
    printf("step add %" PRId64 " -> %" PRId64 "\n", k, m->n);
    return HEGEL_CASE_PASS;
}

static HegelCaseResult rule_reset(HegelCase *tc, void *state, void *userData)
{
    Counter *m = state;

    (void)tc;
    (void)userData;
    m->n = 0;
    printf("step reset -> 0\n");
    return HEGEL_CASE_PASS;
}

static bool reset_allowed(const void *state, void *userData)
{
    const Counter *m = state;

    (void)userData;
    if (m->n == 0) printf("step reset rejected\n");
    return m->n > 0;
}

static HegelCaseResult invariant_non_neg(HegelCase *tc, void *state, void *userData)
{
    const Counter *m = state;

    (void)userData;
    HEGEL_CHECK(tc, m->n >= 0);
    return HEGEL_CASE_PASS;
}

static HegelCaseResult stateful_with(HegelCase *tc, bool reject)
{
    Counter model = {0};
    HegelRule rules[2] = {
        {"RuleAdd", rule_add, NULL},
        {"RuleReset", rule_reset, NULL},
    };
    HegelInvariant invariants[1] = {
        {"InvariantNonNeg", invariant_non_neg},
    };
    HegelStateMachineOptions options = {0};

    if (reject) rules[1].precondition = reset_allowed;
    options.state = &model;
    options.rules = rules;
    options.ruleCount = 2;
    options.invariants = invariants;
    options.invariantCount = 1;
    printf("case\n");
    return HegelRunStateMachine(tc, &options);
}

static HegelCaseResult stateful(HegelCase *tc, void *userData)
{
    (void)userData;
    return stateful_with(tc, false);
}

static HegelCaseResult stateful_reject(HegelCase *tc, void *userData)
{
    (void)userData;
    return stateful_with(tc, true);
}

int main(int argc, char **argv)
{
    const char *program = argc > 1 ? argv[1] : "";
    HegelTest test = {0};
    HegelRunResult result;
    int exitCode;

    test.name = "transcript";
    test.testCount = 32;
    test.seedSet = true;
    test.seed = 42;
    test.derandomize = HEGEL_ENABLED;
    test.databasePath = "";
    test.verbosity = HEGEL_VERBOSITY_QUIET;
    test.statefulStepCount = 6;

    if (strcmp(program, "primitives") == 0) {
        test.property = primitives;
    } else if (strcmp(program, "text") == 0) {
        test.property = text;
    } else if (strcmp(program, "lists") == 0) {
        test.property = lists;
    } else if (strcmp(program, "stateful") == 0) {
        test.property = stateful;
        test.testCount = 8;
    } else if (strcmp(program, "stateful-reject") == 0) {
        test.property = stateful_reject;
        test.testCount = 8;
    } else {
        fprintf(stderr, "transcript-dialectic: no program named '%s'\n", program);
        return 2;
    }

    result = HegelRun(&test);
    exitCode = HegelRunExitCode(&result);
    if (exitCode != 0) HegelPrintRunResult(&result);
    HegelUnloadRunResult(result);
    return exitCode;
}
