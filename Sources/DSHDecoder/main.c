#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/stat.h>
#include <unistd.h>
#include <zstd.h>

int main(int argc, char **argv) {
    if (argc != 2) return EXIT_FAILURE;

    const size_t inputLimit = 64 * 1024 * 1024;
    const size_t outputLimit = 32 * 1024 * 1024;
    const size_t lineLimit = 2 * 1024 * 1024;
    alarm(5);

    int fd = open(argv[1], O_RDONLY | O_NONBLOCK | O_NOFOLLOW);
    if (fd < 0) return EXIT_FAILURE;
    struct stat info;
    FILE *file = NULL;
    if (fstat(fd, &info) == 0 && S_ISREG(info.st_mode) && info.st_size <= (off_t)inputLimit) {
        file = fdopen(fd, "rb");
    }
    if (file == NULL) {
        close(fd);
        return EXIT_FAILURE;
    }

    ZSTD_DStream *stream = ZSTD_createDStream();
    const size_t inputCapacity = ZSTD_DStreamInSize();
    const size_t outputCapacity = ZSTD_DStreamOutSize();
    void *inputBytes = malloc(inputCapacity);
    void *outputBytes = malloc(outputCapacity);
    int result = EXIT_FAILURE;

    if (stream == NULL || inputBytes == NULL || outputBytes == NULL) goto cleanup;
    if (ZSTD_isError(ZSTD_initDStream(stream))) goto cleanup;
    if (ZSTD_isError(ZSTD_DCtx_setParameter(stream, ZSTD_d_windowLogMax, 26))) goto cleanup;

    size_t remaining = 1;
    size_t count;
    size_t totalInput = 0;
    size_t totalOutput = 0;
    size_t lineLength = 0;
    while ((count = fread(inputBytes, 1, inputCapacity, file)) != 0) {
        totalInput += count;
        if (totalInput > inputLimit) goto cleanup;
        ZSTD_inBuffer input = {inputBytes, count, 0};
        do {
            ZSTD_outBuffer output = {outputBytes, outputCapacity, 0};
            remaining = ZSTD_decompressStream(stream, &output, &input);
            if (ZSTD_isError(remaining)) goto cleanup;
            totalOutput += output.pos;
            if (totalOutput > outputLimit) goto cleanup;
            for (size_t index = 0; index < output.pos; index++) {
                if (((unsigned char *)outputBytes)[index] == '\n') {
                    lineLength = 0;
                } else if (++lineLength > lineLimit) {
                    goto cleanup;
                }
            }
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
