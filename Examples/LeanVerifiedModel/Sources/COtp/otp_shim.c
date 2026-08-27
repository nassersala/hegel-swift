#include "COtp.h"
#include <lean/lean.h>

void lean_initialize_runtime_module(void);
lean_object *initialize_otp_Otp(uint8_t builtin);
uint64_t otp_initial(lean_object *unit);

void otp_init(void) {
    static int done = 0;
    if (done) return;
    done = 1;
    lean_initialize_runtime_module();
    lean_object *res = initialize_otp_Otp(1);
    if (lean_io_result_is_ok(res)) {
        lean_dec_ref(res);
    } else {
        lean_io_result_show_error(res);
        lean_dec(res);
    }
    lean_io_mark_end_initialization();
}

uint64_t otp_initial_state(void) { return otp_initial(lean_box(0)); }
