/* Differential-conformance harness: the dialectic mirror of
 * ../transcript-swift and ../transcript-go. Same seed, same settings,
 * same draw sequence with identical arguments — the transcripts must
 * match byte for byte. */

#include <dialectic.h>

#include <inttypes.h>
#include <stdio.h>
#include <string.h>

static HegelCaseResult transcript(HegelCase *tc, void *userData)
{
    int64_t a;
    int64_t b;
    bool c;
    double d;
    HegelBytes e;
    uint64_t bits;
    size_t i;

    (void)userData;
    HEGEL_TRY(tc, HegelDrawInteger(tc, 0, 1000, &a));
    HEGEL_TRY(tc, HegelDrawInteger(tc, INT64_MIN, INT64_MAX, &b));
    HEGEL_TRY(tc, HegelDrawBoolean(tc, 0.5, &c));
    HEGEL_TRY(tc, HegelDrawReal(tc, 0.0, 1.0, &d));
    HEGEL_TRY(tc, HegelDrawBytes(tc, 0, 16, &e));

    memcpy(&bits, &d, sizeof bits);
    printf("case a=%" PRId64 " b=%" PRId64 " c=%s d=%016" PRIx64 " e=",
           a, b, c ? "true" : "false", bits);
    for (i = 0; i < e.length; i++) printf("%02x", e.data[i]);
    printf("\n");
    return HEGEL_CASE_PASS;
}

int main(void)
{
    HegelTest test = {0};
    HegelRunResult result;
    int exitCode;

    test.name = "transcript";
    test.property = transcript;
    test.testCount = 32;
    test.seedSet = true;
    test.seed = 42;
    test.derandomize = HEGEL_ENABLED;
    test.databasePath = "";
    test.verbosity = HEGEL_VERBOSITY_QUIET;

    result = HegelRun(&test);
    exitCode = HegelRunExitCode(&result);
    if (exitCode != 0) HegelPrintRunResult(&result);
    HegelUnloadRunResult(result);
    return exitCode;
}
