#include <stdio.h>
#include <stdlib.h>
#include <zstd.h>

int main(int argc, char **argv) {
    if (argc != 2) return EXIT_FAILURE;

    FILE *file = fopen(argv[1], "rb");
    if (file == NULL) return EXIT_FAILURE;

    ZSTD_DStream *stream = ZSTD_createDStream();
    const size_t inputCapacity = ZSTD_DStreamInSize();
    const size_t outputCapacity = ZSTD_DStreamOutSize();
    void *inputBytes = malloc(inputCapacity);
    void *outputBytes = malloc(outputCapacity);
    int result = EXIT_FAILURE;

    if (stream == NULL || inputBytes == NULL || outputBytes == NULL) goto cleanup;
    if (ZSTD_isError(ZSTD_initDStream(stream))) goto cleanup;

    size_t remaining = 1;
    size_t count;
    while ((count = fread(inputBytes, 1, inputCapacity, file)) != 0) {
        ZSTD_inBuffer input = {inputBytes, count, 0};
        do {
            ZSTD_outBuffer output = {outputBytes, outputCapacity, 0};
            remaining = ZSTD_decompressStream(stream, &output, &input);
            if (ZSTD_isError(remaining)) goto cleanup;
            if (fwrite(outputBytes, 1, output.pos, stdout) != output.pos) goto cleanup;
        } while (input.pos < input.size);
    }
    if (!ferror(file) && remaining == 0 && fflush(stdout) == 0) result = EXIT_SUCCESS;

cleanup:
    ZSTD_freeDStream(stream);
    free(inputBytes);
    free(outputBytes);
    fclose(file);
    return result;
}
