#ifndef MUSTACHE_C
#define MUSTACHE_C

#include <stddef.h>
#include <stdint.h>
#include <stdbool.h>

struct mustache_userdata;

typedef void* mustache_userdata_handle;
typedef void* mustache_writer_handle;
typedef void* mustache_lambda_handle;
typedef void* mustache_template_handle;

typedef enum mustache_status {
    SUCCESS = 0,
    INVALID_TEMPLATE = 1,
    INVALID_USER_DATA = 2,
    INVALID_WRITER = 3,
    PARSE_ERROR = 4,
    INTERPOLATION_ERROR = 5,
} mustache_status;

typedef enum mustache_path_resolution {
    NOT_FOUND_IN_CONTEXT = 0,
    CHAIN_BROKEN = 1,
    ITERATOR_CONSUMED = 2,
    LAMBDA = 3,
    FIELD = 4,
} mustache_path_resolution;

typedef struct mustache_path_resolution_or_error {
    mustache_path_resolution result;
    bool has_error;
    uint32_t error_code;
} mustache_path_resolution_or_error;

typedef struct mustache_path_part {
    const char* value;
    uint32_t size;
} mustache_path_part;

typedef struct mustache_path {
    const mustache_path_part* path;
    uint32_t path_size;
    uint32_t index;
    bool has_index;
} mustache_path;

typedef struct mustache_callbacks {
    mustache_path_resolution (*get)(const mustache_userdata_handle user_data_handle, mustache_path* path, struct mustache_userdata* out_value);
    mustache_path_resolution (*capacity_hint)(const mustache_userdata_handle user_data_handle, mustache_path* path, uint32_t* out_value);
    mustache_path_resolution_or_error (*interpolate)(const mustache_writer_handle writer_handle, const mustache_userdata_handle user_data_handle, mustache_path* path);
    mustache_path_resolution_or_error (*expand_lambda)(const mustache_lambda_handle lambda_handle, const mustache_userdata_handle user_data_handle, mustache_path* path);
} mustache_callbacks;

typedef struct mustache_userdata {
    const mustache_userdata_handle handle;
    const mustache_callbacks callbacks;
} mustache_userdata;


mustache_status mustache_parse_template(const char* template_text, uint32_t template_len, mustache_template_handle* out_template_handle);
mustache_status mustache_render(mustache_template_handle template_handle, mustache_userdata user_data);
mustache_status mustache_interpolate(mustache_writer_handle writer_handle, char* value, uint32_t len);

#endif // MUSTACHE_C