#ifndef AURATUNNEL_LEAF_H
#define AURATUNNEL_LEAF_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct leaf_packet_t {
    const uint8_t *data;
    size_t len;
} leaf_packet_t;

typedef void (*leaf_packet_output_callback_t)(
    const uint8_t *data,
    size_t len,
    void *context
);

int32_t leaf_run_with_config_string(uint16_t rt_id, const char *config);
int32_t leaf_test_config_string(const char *config);
bool leaf_shutdown(uint16_t rt_id);
bool leaf_is_running(uint16_t rt_id);

bool leaf_set_packet_output_callback(
    leaf_packet_output_callback_t callback,
    void *context
);
void leaf_clear_packet_output_callback(void);

size_t leaf_input_packets(const leaf_packet_t *packets, size_t count);

#ifdef __cplusplus
}
#endif

#endif
