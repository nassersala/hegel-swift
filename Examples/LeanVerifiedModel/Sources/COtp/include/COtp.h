#ifndef COTP_H
#define COTP_H
#include <stdint.h>

/// Initialises the Lean runtime and the Otp module. Call once.
void otp_init(void);

/// Packed state/response word: response | screen << 8 | attempts << 16.
uint64_t otp_initial_state(void);

/// 1 if `stim` is enabled in (screen, attempts); exported by Lean.
uint8_t otp_enabled(uint8_t screen, uint32_t attempts, uint8_t stim);

/// step(screen, attempts, stim), packed as above; exported by Lean.
uint64_t otp_step(uint8_t screen, uint32_t attempts, uint8_t stim);

#endif
