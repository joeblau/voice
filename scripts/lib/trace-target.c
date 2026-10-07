// A stand-in process for xctrace to launch on the Mac.
//
// Blau's Instruments template targets a single process (Allocations can't
// record "All Processes"), so the template scripts launch this instead of
// the iOS app. It waits until the file at argv[1] exists or argv[2] seconds
// pass, then exits, which ends the recording.
//
// Usage: trace-target <sentinel path> <timeout seconds>

#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

int main(int argc, char **argv) {
    if (argc != 3) {
        fprintf(stderr, "usage: %s <sentinel path> <timeout seconds>\n", argv[0]);
        return 2;
    }
    const long ticks = (long)(atof(argv[2]) * 10);
    for (long tick = 0; tick < ticks && access(argv[1], F_OK) != 0; tick++) {
        usleep(100000);
    }
    return 0;
}
