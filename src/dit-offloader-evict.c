/*
 * dit-offloader-evict: makes the next read of a file come from the drive, not from memory.
 *
 * Right after a file is written or read, macOS keeps its contents in memory, so reading it
 * back to check a copy would only check that memory. dit-offloader runs this on a file
 * just before checksumming it, so the checksum reads what is actually on the drive.
 *
 *   dit-offloader-evict FILE...   push each file out of memory, then print, one line per
 *                                 file, the percentage still in memory (0 when it worked)
 *
 * Exit status: 0 when every file could be opened, 1 otherwise.
 * macOS: msync(MS_INVALIDATE). Linux (used for the tests): fdatasync, posix_fadvise.
 */
#define _DEFAULT_SOURCE
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

/* Percentage of the mapping's pages that are in memory; -1 if it cannot tell. */
static int resident(void *map, size_t size)
{
    long page = sysconf(_SC_PAGESIZE);
    size_t pages = (size + (size_t)page - 1) / (size_t)page, in = 0, i;
#ifdef __APPLE__
    char *vec = malloc(pages);
#else
    unsigned char *vec = malloc(pages);
#endif
    if (vec == NULL || mincore(map, size, vec) != 0) {
        free(vec);
        return -1;
    }
    for (i = 0; i < pages; i++)
        if (vec[i] & 1)
            in++;
    free(vec);
    return (int)(in * 100 / pages);
}

static int evict(const char *path)
{
    struct stat st;
    void *map;
    int fd = open(path, O_RDONLY), left;

    if (fd < 0 || fstat(fd, &st) != 0) {
        if (fd >= 0)
            close(fd);
        printf("-1\n");
        return 1;
    }
    if (st.st_size == 0) {
        close(fd);
        printf("0\n");
        return 0;
    }
    map = mmap(NULL, (size_t)st.st_size, PROT_READ, MAP_SHARED, fd, 0);
    if (map == MAP_FAILED) {
        close(fd);
        printf("-1\n");
        return 1;
    }
#ifdef __APPLE__
    msync(map, (size_t)st.st_size, MS_INVALIDATE | MS_SYNC);
#else
    fdatasync(fd);
    posix_fadvise(fd, 0, 0, POSIX_FADV_DONTNEED);
#endif
    left = resident(map, (size_t)st.st_size);
    munmap(map, (size_t)st.st_size);
    close(fd);
    printf("%d\n", left);
    return 0;
}

int main(int argc, char **argv)
{
    int i, rc = 0;

    if (argc < 2) {
        fprintf(stderr, "usage: dit-offloader-evict FILE...\n");
        return 2;
    }
    for (i = 1; i < argc; i++)
        rc |= evict(argv[i]);
    return rc;
}
