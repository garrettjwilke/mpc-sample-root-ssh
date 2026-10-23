#define _FILE_OFFSET_BITS 64
#include <arpa/inet.h>
#include <ctype.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <netinet/in.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/statvfs.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

static const char *SD_ROOT = "/media/MPC";
static const char *WEBUI_HTML = "/media/MPC/webui/index.html";

static void url_decode(const char *src, char *dst, size_t dst_sz) {
    size_t i = 0, j = 0;
    while (src[i] && j + 1 < dst_sz) {
        if (src[i] == '%' && isxdigit((unsigned char)src[i + 1]) && isxdigit((unsigned char)src[i + 2])) {
            char hex[3] = { src[i + 1], src[i + 2], 0 };
            dst[j++] = (char)strtol(hex, NULL, 16);
            i += 3;
        } else if (src[i] == '+') {
            dst[j++] = ' ';
            i++;
        } else {
            dst[j++] = src[i++];
        }
    }
    dst[j] = '\0';
}

static void get_query_param(const char *query, const char *key, char *out, size_t out_sz) {
    out[0] = '\0';
    if (!query || !key) return;
    size_t klen = strlen(key);
    const char *p = query;
    while (*p) {
        if (strncmp(p, key, klen) == 0 && p[klen] == '=') {
            p += klen + 1;
            const char *end = strchr(p, '&');
            size_t vlen = end ? (size_t)(end - p) : strlen(p);
            char tmp[1024];
            if (vlen >= sizeof(tmp)) vlen = sizeof(tmp) - 1;
            memcpy(tmp, p, vlen);
            tmp[vlen] = '\0';
            url_decode(tmp, out, out_sz);
            return;
        }
        const char *next = strchr(p, '&');
        if (!next) break;
        p = next + 1;
    }
}

static void json_escape_print(FILE *fp, const char *s) {
    fputc('"', fp);
    for (; *s; s++) {
        unsigned char c = (unsigned char)*s;
        if (c == '"') fputs("\\\"", fp);
        else if (c == '\\') fputs("\\\\", fp);
        else if (c == '\b') fputs("\\b", fp);
        else if (c == '\f') fputs("\\f", fp);
        else if (c == '\n') fputs("\\n", fp);
        else if (c == '\r') fputs("\\r", fp);
        else if (c == '\t') fputs("\\t", fp);
        else if (c < 0x20 || c >= 0x7f) fprintf(fp, "\\u%04x", c);
        else fputc(c, fp);
    }
    fputc('"', fp);
}

static void send_headers(FILE *fp, int status, const char *status_text, const char *content_type, const char *extra) {
    fprintf(fp, "HTTP/1.1 %d %s\r\n", status, status_text);
    fprintf(fp, "Content-Type: %s\r\n", content_type);
    fprintf(fp, "Access-Control-Allow-Origin: *\r\n");
    fprintf(fp, "Access-Control-Allow-Methods: GET, POST, OPTIONS\r\n");
    fprintf(fp, "Access-Control-Allow-Headers: Content-Type, X-Filename\r\n");
    fprintf(fp, "Connection: close\r\n");
    if (extra && extra[0]) fprintf(fp, "%s", extra);
    fprintf(fp, "\r\n");
}

static char *run_cmd_capture(const char *cmd, int *out_status) {
    char full_cmd[2048];
    snprintf(full_cmd, sizeof(full_cmd), "export PATH=\"%s/bin:%s/scripts:$PATH\"; (%s) 2>&1", SD_ROOT, SD_ROOT, cmd);
    FILE *p = popen(full_cmd, "r");
    if (!p) {
        if (out_status) *out_status = -1;
        return strdup("popen failed");
    }
    size_t cap = 16384, len = 0;
    char *buf = malloc(cap);
    size_t n;
    while ((n = fread(buf + len, 1, cap - len - 1, p)) > 0) {
        len += n;
        if (cap - len < 4096) {
            cap *= 2;
            if (cap > 4 * 1024 * 1024) break;
            buf = realloc(buf, cap);
        }
    }
    buf[len] = '\0';
    int st = pclose(p);
    if (out_status) *out_status = WIFEXITED(st) ? WEXITSTATUS(st) : st;
    return buf;
}

static void list_dir_json(FILE *fp, const char *dir_path) {
    fputc('[', fp);
    DIR *d = opendir(dir_path);
    if (d) {
        struct dirent *de;
        int first = 1;
        while ((de = readdir(d)) != NULL) {
            if (de->d_name[0] == '.') continue;
            char full[512];
            snprintf(full, sizeof(full), "%s/%s", dir_path, de->d_name);
            struct stat st;
            if (stat(full, &st) == 0 && S_ISREG(st.st_mode)) {
                if (!first) fputc(',', fp);
                first = 0;
                fputs("{\"name\":", fp);
                json_escape_print(fp, de->d_name);
                fprintf(fp, ",\"size\":%" PRIu64 "}", (uint64_t)st.st_size);
            }
        }
        closedir(d);
    }
    fputc(']', fp);
}

static void handle_status(FILE *fp) {
    send_headers(fp, 200, "OK", "application/json; charset=utf-8", NULL);
    int st = 0;
    char *uname_s = run_cmd_capture("uname -srn", &st);
    char *uptime_s = run_cmd_capture("uptime", &st);
    char *mem_s = run_cmd_capture("free -m", &st);
    char *mounts_s = run_cmd_capture("mount | grep -E '/media/MPC|/data|/factory|/etc/'", &st);
    char *mpc_pid = run_cmd_capture("pidof 'MPC Sample'", &st);

    struct statvfs vfs;
    uint64_t sd_total = 0, sd_free = 0;
    int sd_exec = 0;
    if (statvfs(SD_ROOT, &vfs) == 0) {
        sd_total = (uint64_t)vfs.f_blocks * vfs.f_frsize;
        sd_free = (uint64_t)vfs.f_bavail * vfs.f_frsize;
    }
    if (mounts_s && strstr(mounts_s, "/media/MPC") && !strstr(mounts_s, "noexec")) {
        sd_exec = 1;
    }
    struct stat tk_st;
    int has_toolkit_archive = (stat("/media/MPC/webui/toolkit-bundle.tar.gz", &tk_st) == 0);

    fputs("{", fp);
    fputs("\"uname\":", fp); json_escape_print(fp, uname_s);
    fputs(",\"uptime\":", fp); json_escape_print(fp, uptime_s);
    fputs(",\"memory\":", fp); json_escape_print(fp, mem_s);
    fputs(",\"mounts\":", fp); json_escape_print(fp, mounts_s);
    fputs(",\"mpc_pid\":", fp); json_escape_print(fp, mpc_pid);
    fprintf(fp, ",\"sd_total_bytes\":%" PRIu64 ",\"sd_free_bytes\":%" PRIu64 ",\"sd_exec\":%s,\"has_toolkit_bundle\":%s",
            sd_total, sd_free, sd_exec ? "true" : "false", has_toolkit_archive ? "true" : "false");
    fputs(",\"bins\":", fp); list_dir_json(fp, "/media/MPC/bin");
    fputs(",\"scripts\":", fp); list_dir_json(fp, "/media/MPC/scripts");
    fputs("}\n", fp);

    free(uname_s); free(uptime_s); free(mem_s); free(mounts_s); free(mpc_pid);
}

static int is_safe_subpath(const char *rel) {
    if (!rel || rel[0] == '\0' || strstr(rel, "..") != NULL || rel[0] == '/') return 0;
    return 1;
}

static void handle_client(int client_fd) {
    FILE *fp = fdopen(client_fd, "r+");
    if (!fp) {
        close(client_fd);
        return;
    }

    char req_line[2048];
    if (!fgets(req_line, sizeof(req_line), fp)) {
        fclose(fp);
        return;
    }

    char method[16] = {0}, uri[1024] = {0};
    sscanf(req_line, "%15s %1023s", method, uri);

    size_t content_len = 0;
    char x_filename[256] = {0};
    char line[1024];
    while (fgets(line, sizeof(line), fp)) {
        if (strcmp(line, "\r\n") == 0 || strcmp(line, "\n") == 0) break;
        if (strncasecmp(line, "Content-Length:", 15) == 0) {
            content_len = (size_t)strtoull(line + 15, NULL, 10);
        } else if (strncasecmp(line, "X-Filename:", 11) == 0) {
            char *p = line + 11;
            while (*p == ' ' || *p == '\t') p++;
            size_t l = strlen(p);
            while (l > 0 && (p[l - 1] == '\r' || p[l - 1] == '\n')) p[--l] = '\0';
            strncpy(x_filename, p, sizeof(x_filename) - 1);
        }
    }

    if (strcmp(method, "OPTIONS") == 0) {
        send_headers(fp, 204, "No Content", "text/plain", NULL);
        fclose(fp);
        return;
    }

    char path[1024] = {0};
    const char *query = strchr(uri, '?');
    if (query) {
        size_t plen = (size_t)(query - uri);
        if (plen >= sizeof(path)) plen = sizeof(path) - 1;
        memcpy(path, uri, plen);
        query++;
    } else {
        strncpy(path, uri, sizeof(path) - 1);
    }

    if (strcmp(path, "/") == 0 || strcmp(path, "/index.html") == 0 || strcmp(path, "/testapp") == 0) {
        FILE *hf = fopen(WEBUI_HTML, "rb");
        if (!hf) {
            send_headers(fp, 404, "Not Found", "text/plain", NULL);
            fprintf(fp, "Web UI file not found at %s\n", WEBUI_HTML);
            fclose(fp);
            return;
        }
        send_headers(fp, 200, "OK", "text/html; charset=utf-8", NULL);
        char buf[8192];
        size_t n;
        while ((n = fread(buf, 1, sizeof(buf), hf)) > 0) {
            fwrite(buf, 1, n, fp);
        }
        fclose(hf);
        fclose(fp);
        return;
    }

    if (strcmp(path, "/api/status") == 0) {
        handle_status(fp);
        fclose(fp);
        return;
    }

    if (strcmp(path, "/api/exec") == 0 && strcmp(method, "POST") == 0) {
        char *body = calloc(1, content_len + 1);
        if (content_len > 0) fread(body, 1, content_len, fp);
        int status = 0;
        char *out = run_cmd_capture(body, &status);
        send_headers(fp, 200, "OK", "application/json; charset=utf-8", NULL);
        fprintf(fp, "{\"exit_code\":%d,\"output\":", status);
        json_escape_print(fp, out);
        fprintf(fp, "}\n");
        free(out);
        free(body);
        fclose(fp);
        return;
    }

    if (strcmp(path, "/api/file") == 0) {
        char rel[256];
        get_query_param(query, "path", rel, sizeof(rel));
        if (!is_safe_subpath(rel)) {
            send_headers(fp, 400, "Bad Request", "application/json", NULL);
            fprintf(fp, "{\"error\":\"Invalid path\"}\n");
            fclose(fp);
            return;
        }
        char full[512];
        snprintf(full, sizeof(full), "%s/%s", SD_ROOT, rel);
        if (strcmp(method, "GET") == 0) {
            FILE *f = fopen(full, "rb");
            if (!f) {
                send_headers(fp, 404, "Not Found", "application/json", NULL);
                fprintf(fp, "{\"error\":\"File not found\"}\n");
                fclose(fp);
                return;
            }
            fseek(f, 0, SEEK_END);
            long sz = ftell(f);
            fseek(f, 0, SEEK_SET);
            if (sz < 0) sz = 0;
            char *content = calloc(1, (size_t)sz + 1);
            fread(content, 1, (size_t)sz, f);
            fclose(f);
            send_headers(fp, 200, "OK", "application/json; charset=utf-8", NULL);
            fputs("{\"path\":", fp); json_escape_print(fp, rel);
            fputs(",\"content\":", fp); json_escape_print(fp, content);
            fputs("}\n", fp);
            free(content);
        } else if (strcmp(method, "POST") == 0) {
            char *body = calloc(1, content_len + 1);
            if (content_len > 0) fread(body, 1, content_len, fp);
            FILE *f = fopen(full, "wb");
            if (!f) {
                send_headers(fp, 500, "Internal Server Error", "application/json", NULL);
                fprintf(fp, "{\"error\":\"Cannot write file\"}\n");
                free(body);
                fclose(fp);
                return;
            }
            fwrite(body, 1, content_len, f);
            fclose(f);
            chmod(full, 0755);
            free(body);
            send_headers(fp, 200, "OK", "application/json; charset=utf-8", NULL);
            fprintf(fp, "{\"ok\":true}\n");
        }
        fclose(fp);
        return;
    }

    if (strcmp(path, "/api/upload") == 0 && strcmp(method, "POST") == 0) {
        char dest[64], name[256];
        get_query_param(query, "dest", dest, sizeof(dest));
        get_query_param(query, "name", name, sizeof(name));
        if (!name[0] && x_filename[0]) strncpy(name, x_filename, sizeof(name) - 1);
        if (!is_safe_subpath(name) || (strcmp(dest, "bin") != 0 && strcmp(dest, "scripts") != 0 && strcmp(dest, "webui") != 0)) {
            send_headers(fp, 400, "Bad Request", "application/json", NULL);
            fprintf(fp, "{\"error\":\"Invalid upload destination or filename\"}\n");
            fclose(fp);
            return;
        }
        char full[512];
        snprintf(full, sizeof(full), "%s/%s/%s", SD_ROOT, dest, name);
        FILE *outf = fopen(full, "wb");
        if (!outf) {
            send_headers(fp, 500, "Internal Server Error", "application/json", NULL);
            fprintf(fp, "{\"error\":\"Cannot open target file for writing\"}\n");
            fclose(fp);
            return;
        }
        char buf[16384];
        size_t rem = content_len;
        while (rem > 0) {
            size_t to_read = rem < sizeof(buf) ? rem : sizeof(buf);
            size_t n = fread(buf, 1, to_read, fp);
            if (n == 0) break;
            fwrite(buf, 1, n, outf);
            rem -= n;
        }
        fclose(outf);
        chmod(full, 0755);
        send_headers(fp, 200, "OK", "application/json; charset=utf-8", NULL);
        fprintf(fp, "{\"ok\":true,\"path\":\"%s\",\"bytes\":%zu}\n", full, content_len);
        fclose(fp);
        return;
    }

    if (strcmp(path, "/api/ram/maps") == 0) {
        char filter[64];
        get_query_param(query, "filter", filter, sizeof(filter));
        if (!filter[0]) strcpy(filter, "app");
        char cmd[256];
        snprintf(cmd, sizeof(cmd), "/media/MPC/bin/mpc-memdump maps '%s'", filter);
        int st = 0;
        char *out = run_cmd_capture(cmd, &st);
        send_headers(fp, 200, "OK", "application/json; charset=utf-8", NULL);
        fprintf(fp, "{\"exit_code\":%d,\"output\":", st);
        json_escape_print(fp, out);
        fprintf(fp, "}\n");
        free(out);
        fclose(fp);
        return;
    }

    if (strcmp(path, "/api/ram/search") == 0) {
        char q[256], filter[64];
        get_query_param(query, "q", q, sizeof(q));
        get_query_param(query, "filter", filter, sizeof(filter));
        if (!filter[0]) strcpy(filter, "app");
        // Sanitize single quotes
        for (char *p = q; *p; p++) if (*p == '\'') *p = '.';
        for (char *p = filter; *p; p++) if (*p == '\'') *p = '.';
        char cmd[512];
        snprintf(cmd, sizeof(cmd), "/media/MPC/bin/mpc-memdump search -f '%s' '%s'", filter, q);
        int st = 0;
        char *out = run_cmd_capture(cmd, &st);
        send_headers(fp, 200, "OK", "application/json; charset=utf-8", NULL);
        fprintf(fp, "{\"exit_code\":%d,\"output\":", st);
        json_escape_print(fp, out);
        fprintf(fp, "}\n");
        free(out);
        fclose(fp);
        return;
    }

    if (strcmp(path, "/api/ram/range") == 0) {
        char addr[64], size_s[64], dl[16];
        get_query_param(query, "addr", addr, sizeof(addr));
        get_query_param(query, "size", size_s, sizeof(size_s));
        get_query_param(query, "download", dl, sizeof(dl));
        uint64_t start = strtoull(addr, NULL, 0);
        uint64_t len = strtoull(size_s, NULL, 0);
        if (len == 0) len = 256;
        if (len > 64 * 1024 * 1024) len = 64 * 1024 * 1024;

        char cmd[256];
        if (strcmp(dl, "1") == 0) {
            char extra[256];
            snprintf(extra, sizeof(extra), "Content-Disposition: attachment; filename=\"ram_0x%" PRIx64 "_%" PRIu64 ".bin\"\r\n", start, len);
            send_headers(fp, 200, "OK", "application/octet-stream", extra);
            fflush(fp);
            snprintf(cmd, sizeof(cmd), "/media/MPC/bin/mpc-memdump range 0x%" PRIx64 " %" PRIu64, start, len);
            FILE *p = popen(cmd, "r");
            if (p) {
                char buf[16384];
                size_t n;
                while ((n = fread(buf, 1, sizeof(buf), p)) > 0) fwrite(buf, 1, n, fp);
                pclose(p);
            }
            fclose(fp);
            return;
        } else {
            if (len > 16384) len = 16384;
            snprintf(cmd, sizeof(cmd), "/media/MPC/bin/mpc-memdump range 0x%" PRIx64 " %" PRIu64 " | xxd", start, len);
            int st = 0;
            char *out = run_cmd_capture(cmd, &st);
            send_headers(fp, 200, "OK", "application/json; charset=utf-8", NULL);
            fprintf(fp, "{\"addr\":\"0x%" PRIx64 "\",\"size\":%" PRIu64 ",\"hexdump\":", start, len);
            json_escape_print(fp, out);
            fprintf(fp, "}\n");
            free(out);
            fclose(fp);
            return;
        }
    }

    if (strcmp(path, "/api/ram/dump") == 0) {
        char filter[64];
        get_query_param(query, "filter", filter, sizeof(filter));
        if (!filter[0]) strcpy(filter, "heap");
        for (char *p = filter; *p; p++) if (!isalnum((unsigned char)*p) && *p != '_' && *p != '-') *p = '_';

        char extra[256];
        snprintf(extra, sizeof(extra), "Content-Disposition: attachment; filename=\"mpc_ram_%s.tar\"\r\n", filter);
        send_headers(fp, 200, "OK", "application/x-tar", extra);
        fflush(fp);

        char cmd[512];
        snprintf(cmd, sizeof(cmd),
                 "D=\"/media/MPC/.ram_dump_web_$$\" && mkdir -p \"$D\" && "
                 "/media/MPC/bin/mpc-memdump dump -f '%s' -o \"$D\" 2>/dev/null && "
                 "tar -cf - -C \"$D\" . && rm -rf \"$D\"",
                 filter);
        FILE *p = popen(cmd, "r");
        if (p) {
            char buf[32768];
            size_t n;
            while ((n = fread(buf, 1, sizeof(buf), p)) > 0) {
                if (fwrite(buf, 1, n, fp) != n) break;
            }
            pclose(p);
        }
        fclose(fp);
        return;
    }

    send_headers(fp, 404, "Not Found", "application/json", NULL);
    fprintf(fp, "{\"error\":\"Not found\"}\n");
    fclose(fp);
}

int main(int argc, char **argv) {
    int port = 8080;
    const char *bind_ip = "0.0.0.0";
    if (argc > 1) port = atoi(argv[1]);
    if (argc > 2) bind_ip = argv[2];

    signal(SIGCHLD, SIG_IGN);
    signal(SIGPIPE, SIG_IGN);

    int srv = socket(AF_INET, SOCK_STREAM, 0);
    if (srv < 0) {
        perror("socket");
        return 1;
    }
    int opt = 1;
    setsockopt(srv, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt));

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_port = htons((uint16_t)port);
    inet_pton(AF_INET, bind_ip, &addr.sin_addr);

    if (bind(srv, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        perror("bind");
        return 1;
    }
    if (listen(srv, 16) < 0) {
        perror("listen");
        return 1;
    }

    fprintf(stderr, "mpc-webui listening on http://%s:%d\n", bind_ip, port);
    while (1) {
        int client = accept(srv, NULL, NULL);
        if (client < 0) continue;
        pid_t pid = fork();
        if (pid == 0) {
            close(srv);
            handle_client(client);
            _exit(0);
        }
        close(client);
    }
    return 0;
}
