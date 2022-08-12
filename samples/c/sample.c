#include <stdio.h>
#include <stdint.h>
#include <inttypes.h>
#include <string.h>
#include <errno.h>
#include <stdbool.h>
#include <time.h>

#include "mustache.h"

typedef struct Data {
    char* title;
    char* body;
} Data;

mustache_path_resolution capacity_hint(const mustache_userdata_handle user_data_handle, mustache_path* path, uint32_t* out_value) {

    Data* data = (Data*)user_data_handle;

    if (path->path_size == 1) {

        const mustache_path_part* part = path->path;
        if (strncmp(part->value, "title", part->size) == 0) {

            *out_value = strlen(data->title);
            return FIELD;

        } else if (strncmp(part->value, "body", part->size) == 0) {

            *out_value = strlen(data->body);
            return FIELD;
        }
    }

    return NOT_FOUND_IN_CONTEXT;
}

mustache_path_resolution interpolate(const mustache_writer_handle writer_handle, mustache_write_fn write_fn, const mustache_userdata_handle user_data_handle, mustache_path* path) {

    Data* data = (Data*)user_data_handle;
    
    if (path->path_size == 1) {

        const mustache_path_part* part = path->path;

        if (strncmp(part->value, "title", part->size) == 0) {

            int status = write_fn(writer_handle, data->title, strlen(data->title));
            if (status != SUCCESS) return CHAIN_BROKEN;
            return FIELD;

        } else if (strncmp(part->value, "body", part->size) == 0) {

            int status = write_fn(writer_handle, data->body, strlen(data->body));
            if (status != SUCCESS) return CHAIN_BROKEN;
            return FIELD;
        }
    }

    return NOT_FOUND_IN_CONTEXT;
}

int main(int argc, char **argv)
{
    const char* template_text = "<title>{{title}}</title><h1>{{ title }}</h1><div>{{{body}}}</div>";
    mustache_template_handle template;
    int status = mustache_create_template(template_text, strlen(template_text) , &template);
    if (status != SUCCESS) {
        fprintf(stderr, "error: failed to parse the template\n");
        return 2;
    }

    Data data;
    data.body = "Hello, Mustache!";
    data.title = "This is a really simple test of the rendering!";

    mustache_userdata user_data;
    user_data.handle = &data;
    user_data.capacity_hint = &capacity_hint;
    user_data.interpolate = &interpolate;

    char* buffer;
    uint32_t buffer_len;

    status = mustache_render(template, user_data, &buffer, &buffer_len);
    if (status != SUCCESS) {
        fprintf(stderr, "error: failed to render\n");
        return 2;
    }

    fprintf(stdout, "Rendering this simple template 1 million times\n%s\n\n", buffer);

    long total = 0;
    clock_t start = clock();
    for(int i=0; i<1000000;i++) {
        status = mustache_render(template, user_data, &buffer, &buffer_len);
        if (status != SUCCESS) return 2;
        total += buffer_len;
    }
    clock_t end = clock();
    float elapsed = (float)(end - start)/CLOCKS_PER_SEC;

    fprintf(stdout, "C FFI\n");
    fprintf(stdout, "Total time %.3f s\n", elapsed);
    fprintf(stdout, "%.3f ops/s\n", (float)1000000 / elapsed);
    fprintf(stdout, "%d ns/iter\n", (int)(elapsed * 1000));
    fprintf(stdout, "%.3f MB/s\n", (float)total / 1024 / 1024 / elapsed);

    return 0;
}