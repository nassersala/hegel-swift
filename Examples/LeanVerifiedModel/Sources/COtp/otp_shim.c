#include "COtp.h"
#include <lean/lean.h>
#include <pthread.h>

void lean_initialize_runtime_module(void);
void lean_initialize_thread(void);
lean_object *initialize_otp_Otp(uint8_t builtin);
lean_object *initialize_otp_Bank(uint8_t builtin);
uint64_t otp_initial(lean_object *unit);
uint64_t bank_initial(lean_object *unit);

static void otp_init_once(void) {
    lean_initialize_runtime_module();
    lean_object *(*inits[])(uint8_t) = { initialize_otp_Otp, initialize_otp_Bank };
    for (int i = 0; i < 2; i++) {
        lean_object *res = inits[i](1);
        if (lean_io_result_is_ok(res)) {
            lean_dec_ref(res);
        } else {
            lean_io_result_show_error(res);
            lean_dec(res);
        }
    }
    lean_io_mark_end_initialization();
}

/// Global init exactly once (tests run on several threads at once), and
/// per-thread init for threads Lean did not create.
void otp_init(void) {
    static pthread_once_t once = PTHREAD_ONCE_INIT;
    pthread_once(&once, otp_init_once);
    static __thread int thread_ready = 0;
    if (!thread_ready) {
        thread_ready = 1;
        lean_initialize_thread();
    }
}

uint64_t otp_initial_state(void) { return otp_initial(lean_box(0)); }
uint64_t bank_initial_state(void) { return bank_initial(lean_box(0)); }
