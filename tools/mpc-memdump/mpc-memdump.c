#define _FILE_OFFSET_BITS 64
#include <ctype.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

typedef struct {
    uint64_t start;
    uint64_t end;
    char perms[8];
    uint64_t offset;
    char dev[16];
    uint64_t inode;
    char path[512];
} map_region_t;

static int find_pid_by_name(const char *target) {
    DIR *d = opendir("/proc");
    if (!d) return -1;
    struct dirent *de;
    while ((de = readdir(d)) != NULL) {
        if (!isdigit((unsigned char)de->d_name[0])) continue;
        int pid = atoi(de->d_name);
        char comm_path[64];
        snprintf(comm_path, sizeof(comm_path), "/proc/%d/comm", pid);
        FILE *f = fopen(comm_path, "r");
        if (f) {
            char buf[256] = {0};
            if (fgets(buf, sizeof(buf), f)) {
                size_t len = strlen(buf);
                while (len > 0 && (buf[len - 1] == '\n' || buf[len - 1] == '\r')) buf[--len] = '\0';
                if (strcmp(buf, target) == 0) {
                    fclose(f);
                    closedir(d);
                    return pid;
                }
            }
            fclose(f);
        }
        char cmd_path[64];
        snprintf(cmd_path, sizeof(cmd_path), "/proc/%d/cmdline", pid);
        f = fopen(cmd_path, "r");
        if (f) {
            char buf[512] = {0};
            size_t n = fread(buf, 1, sizeof(buf) - 1, f);
            fclose(f);
            if (n > 0 && strstr(buf, target) != NULL && strstr(buf, "mpc-memdump") == NULL) {
                closedir(d);
                return pid;
            }
        }
    }
    closedir(d);
    return -1;
}

static int parse_maps(int pid, map_region_t **out_regions, size_t *out_count) {
    char maps_path[64];
    snprintf(maps_path, sizeof(maps_path), "/proc/%d/maps", pid);
    FILE *f = fopen(maps_path, "r");
    if (!f) return -1;

    size_t cap = 256, count = 0;
    map_region_t *regions = calloc(cap, sizeof(map_region_t));
    char line[1024];
    while (fgets(line, sizeof(line), f)) {
        if (count >= cap) {
            cap *= 2;
            regions = realloc(regions, cap * sizeof(map_region_t));
        }
        map_region_t *r = &regions[count];
        memset(r, 0, sizeof(*r));
        int pos = 0;
        int matched = sscanf(line, "%" SCNx64 "-%" SCNx64 " %7s %" SCNx64 " %15s %" SCNu64 " %n",
                             &r->start, &r->end, r->perms, &r->offset, r->dev, &r->inode, &pos);
        if (matched >= 6) {
            if (pos > 0 && line[pos] != '\0') {
                char *p = line + pos;
                while (*p == ' ' || *p == '\t') p++;
                size_t l = strlen(p);
                while (l > 0 && (p[l - 1] == '\n' || p[l - 1] == '\r')) p[--l] = '\0';
                strncpy(r->path, p, sizeof(r->path) - 1);
            }
            count++;
        }
    }
    fclose(f);
    *out_regions = regions;
    *out_count = count;
    return 0;
}

static int region_matches_filter(const map_region_t *r, const char *filter) {
    if (r->perms[0] != 'r') return 0; // Not readable
    if (strcmp(r->path, "[vvar]") == 0) return 0;
    if (!filter || strcmp(filter, "all") == 0) return 1;
    if (strcmp(filter, "heap") == 0) return strcmp(r->path, "[heap]") == 0;
    if (strcmp(filter, "stack") == 0) return strstr(r->path, "[stack") != NULL;
    if (strcmp(filter, "anon") == 0) return r->path[0] == '\0' || strcmp(r->path, "[heap]") == 0;
    if (strcmp(filter, "rw") == 0) return r->perms[1] == 'w' && strcmp(r->dev, "00:00") == 0;
    if (strcmp(filter, "app") == 0) return strstr(r->path, "MPC Sample") != NULL || strcmp(r->path, "[heap]") == 0;
    return strstr(r->path, filter) != NULL;
}

static void sanitize_label(const char *in, char *out, size_t out_sz) {
    if (!in || in[0] == '\0') {
        strncpy(out, "anon", out_sz - 1);
        return;
    }
    const char *base = strrchr(in, '/');
    if (base) in = base + 1;
    size_t j = 0;
    for (size_t i = 0; in[i] != '\0' && j + 1 < out_sz; i++) {
        char c = in[i];
        if (isalnum((unsigned char)c) || c == '.' || c == '-' || c == '_') {
            out[j++] = c;
        } else if (c == ' ') {
            out[j++] = '_';
        }
    }
    out[j] = '\0';
    if (j == 0) strncpy(out, "region", out_sz - 1);
}

static void usage(const char *prog) {
    fprintf(stderr,
        "Usage: %s <command> [options]\n\n"
        "Commands:\n"
        "  maps   [-p PID|-n NAME] [filter]            List memory regions & total sizes\n"
        "  dump   [-p PID|-n NAME] [-f FILTER]         Stream regions as raw files into a directory\n"
        "         [-o DIR]                             or stream to stdout (-o -)\n"
        "  range  [-p PID|-n NAME] <start_hex> <size>  Dump exact virtual address range to stdout\n"
        "  search [-p PID|-n NAME] [-f FILTER] <str>   Search live RAM for ASCII string or hex (0x...)\n\n"
        "Filters (-f):\n"
        "  rw     All writable private/anon + heap + stack RAM (default for dump/search)\n"
        "  heap   Only [heap] (~115 MB)\n"
        "  app    'MPC Sample' code/data segments + [heap]\n"
        "  anon   Anonymous mappings + [heap]\n"
        "  all    Every readable mapping in the process (~640 MB)\n"
        "  <str>  Any mapping whose path contains <str>\n",
        prog);
}

int main(int argc, char **argv) {
    if (argc < 2 || strcmp(argv[1], "-h") == 0 || strcmp(argv[1], "--help") == 0) {
        usage(argv[0]);
        return 0;
    }
    const char *cmd = argv[1];
    int pid = -1;
    const char *proc_name = "MPC Sample";
    const char *filter = NULL;
    const char *out_dir = ".";

    int argi = 2;
    while (argi < argc && argv[argi][0] == '-' && strcmp(argv[argi], "-") != 0) {
        if (strcmp(argv[argi], "-p") == 0 && argi + 1 < argc) {
            pid = atoi(argv[++argi]);
        } else if (strcmp(argv[argi], "-n") == 0 && argi + 1 < argc) {
            proc_name = argv[++argi];
        } else if (strcmp(argv[argi], "-f") == 0 && argi + 1 < argc) {
            filter = argv[++argi];
        } else if (strcmp(argv[argi], "-o") == 0 && argi + 1 < argc) {
            out_dir = argv[++argi];
        } else {
            break;
        }
        argi++;
    }

    if (pid < 0) {
        pid = find_pid_by_name(proc_name);
        if (pid < 0) {
            fprintf(stderr, "ERROR: Could not find running process '%s'\n", proc_name);
            return 1;
        }
    }

    map_region_t *regions = NULL;
    size_t count = 0;
    if (parse_maps(pid, &regions, &count) != 0) {
        fprintf(stderr, "ERROR: Cannot read /proc/%d/maps: %s\n", pid, strerror(errno));
        return 1;
    }

    if (strcmp(cmd, "maps") == 0) {
        if (!filter && argi < argc) filter = argv[argi];
        if (!filter) filter = "all";
        uint64_t total_bytes = 0;
        size_t matched = 0;
        printf("PID: %d (%s) | Filter: %s\n", pid, proc_name, filter);
        printf("%-18s %-18s %-6s %10s  %s\n", "START", "END", "PERMS", "SIZE (KB)", "PATH");
        printf("--------------------------------------------------------------------------------\n");
        for (size_t i = 0; i < count; i++) {
            map_region_t *r = &regions[i];
            if (!region_matches_filter(r, filter)) continue;
            uint64_t sz = r->end - r->start;
            total_bytes += sz;
            matched++;
            printf("0x%016" PRIx64 " 0x%016" PRIx64 " %-6s %10" PRIu64 "  %s\n",
                   r->start, r->end, r->perms, sz / 1024, r->path[0] ? r->path : "[anon]");
        }
        printf("--------------------------------------------------------------------------------\n");
        printf("Regions: %zu | Total readable size: %.2f MB (%" PRIu64 " bytes)\n",
               matched, (double)total_bytes / (1024.0 * 1024.0), total_bytes);
        free(regions);
        return 0;
    }

    char mem_path[64];
    snprintf(mem_path, sizeof(mem_path), "/proc/%d/mem", pid);
    int mem_fd = open(mem_path, O_RDONLY);
    if (mem_fd < 0) {
        fprintf(stderr, "ERROR: Cannot open %s: %s\n", mem_path, strerror(errno));
        free(regions);
        return 1;
    }

    if (strcmp(cmd, "range") == 0) {
        if (argi + 1 >= argc) {
            fprintf(stderr, "Usage: %s range [-p PID] <start_hex> <size_bytes_or_hex>\n", argv[0]);
            close(mem_fd);
            return 1;
        }
        uint64_t start = strtoull(argv[argi], NULL, 0);
        uint64_t length = strtoull(argv[argi + 1], NULL, 0);
        size_t chunk_sz = 256 * 1024;
        uint8_t *buf = malloc(chunk_sz);
        uint64_t remaining = length;
        uint64_t cur = start;
        while (remaining > 0) {
            size_t to_read = remaining < chunk_sz ? (size_t)remaining : chunk_sz;
            ssize_t n = pread(mem_fd, buf, to_read, (off_t)cur);
            if (n <= 0) break;
            fwrite(buf, 1, (size_t)n, stdout);
            cur += (uint64_t)n;
            remaining -= (uint64_t)n;
        }
        free(buf);
        close(mem_fd);
        free(regions);
        return 0;
    }

    if (strcmp(cmd, "search") == 0) {
        if (argi >= argc) {
            fprintf(stderr, "Usage: %s search [-f FILTER] <ascii_string_or_0xHEX>\n", argv[0]);
            close(mem_fd);
            return 1;
        }
        if (!filter) filter = "rw";
        const char *needle_arg = argv[argi];
        uint8_t needle[256];
        size_t needle_len = 0;
        if (strncmp(needle_arg, "0x", 2) == 0 || strncmp(needle_arg, "0X", 2) == 0) {
            const char *hex = needle_arg + 2;
            size_t hlen = strlen(hex);
            for (size_t i = 0; i + 1 < hlen && needle_len < sizeof(needle); i += 2) {
                unsigned int byte = 0;
                if (sscanf(hex + i, "%2x", &byte) == 1) {
                    needle[needle_len++] = (uint8_t)byte;
                }
            }
        } else {
            needle_len = strlen(needle_arg);
            if (needle_len > sizeof(needle)) needle_len = sizeof(needle);
            memcpy(needle, needle_arg, needle_len);
        }
        if (needle_len == 0) {
            fprintf(stderr, "ERROR: Empty search pattern\n");
            close(mem_fd);
            return 1;
        }

        size_t chunk_sz = 1024 * 1024;
        uint8_t *buf = malloc(chunk_sz + needle_len);
        size_t hits = 0;
        for (size_t i = 0; i < count; i++) {
            map_region_t *r = &regions[i];
            if (!region_matches_filter(r, filter)) continue;
            uint64_t cur = r->start;
            while (cur < r->end) {
                uint64_t rem = r->end - cur;
                size_t to_read = rem < chunk_sz ? (size_t)rem : chunk_sz;
                ssize_t n = pread(mem_fd, buf, to_read, (off_t)cur);
                if (n <= 0) {
                    cur += 4096;
                    continue;
                }
                for (ssize_t j = 0; j + (ssize_t)needle_len <= n; j++) {
                    if (buf[j] == needle[0] && memcmp(buf + j, needle, needle_len) == 0) {
                        uint64_t hit_addr = cur + (uint64_t)j;
                        printf("0x%016" PRIx64 "  [%s %s]  ", hit_addr, r->perms, r->path[0] ? r->path : "anon");
                        for (size_t k = 0; k < 48 && j + (ssize_t)k < n; k++) {
                            uint8_t c = buf[j + k];
                            putchar((c >= 32 && c < 127) ? c : '.');
                        }
                        putchar('\n');
                        hits++;
                        if (hits >= 500) {
                            printf("... reached 500 matches limit ...\n");
                            goto search_done;
                        }
                    }
                }
                cur += (uint64_t)n;
            }
        }
search_done:
        fprintf(stderr, "Search complete: %zu matches found (PID %d, filter=%s)\n", hits, pid, filter);
        free(buf);
        close(mem_fd);
        free(regions);
        return 0;
    }

    if (strcmp(cmd, "dump") == 0) {
        if (!filter) filter = "rw";
        mkdir(out_dir, 0755);
        char idx_path[512];
        snprintf(idx_path, sizeof(idx_path), "%s/maps.txt", out_dir);
        FILE *idx = fopen(idx_path, "w");
        if (!idx) {
            fprintf(stderr, "ERROR: Cannot write %s: %s\n", idx_path, strerror(errno));
            close(mem_fd);
            return 1;
        }
        fprintf(idx, "# PID=%d (%s) filter=%s\n", pid, proc_name, filter);
        size_t chunk_sz = 1024 * 1024;
        uint8_t *buf = calloc(1, chunk_sz);
        uint64_t total_dumped = 0;
        size_t dumped_regions = 0;

        for (size_t i = 0; i < count; i++) {
            map_region_t *r = &regions[i];
            if (!region_matches_filter(r, filter)) continue;
            char label[64];
            sanitize_label(r->path, label, sizeof(label));
            char fname[256];
            snprintf(fname, sizeof(fname), "%016" PRIx64 "-%016" PRIx64 "_%s_%s.bin",
                     r->start, r->end, r->perms, label);
            char full_path[768];
            snprintf(full_path, sizeof(full_path), "%s/%s", out_dir, fname);

            FILE *outf = fopen(full_path, "wb");
            if (!outf) continue;

            uint64_t cur = r->start;
            uint64_t region_written = 0;
            while (cur < r->end) {
                uint64_t rem = r->end - cur;
                size_t to_read = rem < chunk_sz ? (size_t)rem : chunk_sz;
                ssize_t n = pread(mem_fd, buf, to_read, (off_t)cur);
                if (n > 0) {
                    fwrite(buf, 1, (size_t)n, outf);
                    cur += (uint64_t)n;
                    region_written += (uint64_t)n;
                } else {
                    // Unreadable page: pad with zeros so file offsets match virtual addresses
                    size_t pad = rem < 4096 ? (size_t)rem : 4096;
                    memset(buf, 0, pad);
                    fwrite(buf, 1, pad, outf);
                    cur += pad;
                    region_written += pad;
                }
            }
            fclose(outf);
            fprintf(idx, "0x%016" PRIx64 " 0x%016" PRIx64 " %s %10" PRIu64 " %s\t%s\n",
                    r->start, r->end, r->perms, region_written, fname, r->path[0] ? r->path : "[anon]");
            total_dumped += region_written;
            dumped_regions++;
        }
        fclose(idx);
        fprintf(stderr, "Dumped %zu regions (%.2f MB) from PID %d into %s\n",
                dumped_regions, (double)total_dumped / (1024.0 * 1024.0), pid, out_dir);
        free(buf);
        close(mem_fd);
        free(regions);
        return 0;
    }

    usage(argv[0]);
    close(mem_fd);
    free(regions);
    return 1;
}
