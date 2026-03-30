/*
 * cleanup_env.so — LD_PRELOAD library for nix-portable-bundle
 *
 * Problem: A bundled binary needs LD_LIBRARY_PATH to find its co-bundled
 * libraries (glibc, libstdc++, etc.), but child processes must NOT inherit
 * this LD_LIBRARY_PATH — a child's interpreter (e.g. system ld-linux 2.17)
 * loading the bundle's glibc 2.42 is undefined behavior and crashes.
 *
 * Solution: This library, loaded via LD_PRELOAD, does two things:
 *
 *   1. Constructor (runs after ld-linux resolves all libraries):
 *      - Saves LD_LIBRARY_PATH and LD_PRELOAD
 *      - Removes them from environ
 *      → Child processes launched via execv/execvp (which use environ
 *        internally in glibc) get a clean environment.
 *
 *   2. exec*() wrappers:
 *      - Self re-exec (detected via /proc/self/exe comparison):
 *        Restores LD_LIBRARY_PATH and LD_PRELOAD so the re-exec'd process
 *        can find its libraries.
 *      - Child process exec with explicit envp:
 *        Strips LD_LIBRARY_PATH and LD_PRELOAD from the envp.
 *
 * This preserves:
 *   - ELF layout (no patchelf --set-rpath, no NOTE segment corruption)
 *   - /proc/self/exe (binary is executed directly, not via ld-linux wrapper)
 *   - Library resolution for self re-exec (Node.js SEA does this)
 *   - Clean environment for child processes (gh, git, etc.)
 */

#define _GNU_SOURCE
#include <dlfcn.h>
#include <errno.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

/* Saved from the original environment before cleanup */
static char saved_lib_path[8192];
static char saved_preload[8192];
static char self_exe[PATH_MAX];

/* Real libc functions resolved via dlsym */
static int (*real_execve)(const char *, char *const [], char *const []);
static int (*real_execvp)(const char *, char *const []);
static int (*real_execvpe)(const char *, char *const [], char *const []);

__attribute__((constructor))
static void cleanup_init(void) {
    const char *v;

    /* Resolve /proc/self/exe for self re-exec detection */
    ssize_t n = readlink("/proc/self/exe", self_exe, sizeof(self_exe) - 1);
    if (n > 0) self_exe[n] = '\0';

    /* Save LD_LIBRARY_PATH and LD_PRELOAD before cleaning */
    v = getenv("LD_LIBRARY_PATH");
    if (v) snprintf(saved_lib_path, sizeof(saved_lib_path), "%s", v);

    v = getenv("LD_PRELOAD");
    if (v) snprintf(saved_preload, sizeof(saved_preload), "%s", v);

    /* Clean environ — exec* functions that use environ internally
     * (execv, execvp, execl, execlp) will pass this cleaned environ
     * to child processes without us needing to intercept them. */
    unsetenv("LD_LIBRARY_PATH");
    unsetenv("LD_PRELOAD");

    /* Resolve real functions for our wrappers */
    real_execve  = dlsym(RTLD_NEXT, "execve");
    real_execvp  = dlsym(RTLD_NEXT, "execvp");
    real_execvpe = dlsym(RTLD_NEXT, "execvpe");
}

/* ---------- helpers ---------- */

static int is_self_reexec(const char *pathname) {
    if (!pathname || !self_exe[0])
        return 0;
    if (strcmp(pathname, "/proc/self/exe") == 0)
        return 1;
    if (strcmp(pathname, self_exe) == 0)
        return 1;
    char resolved[PATH_MAX];
    if (realpath(pathname, resolved) && strcmp(resolved, self_exe) == 0)
        return 1;
    return 0;
}

static int envp_len(char *const envp[]) {
    int n = 0;
    if (envp) while (envp[n]) n++;
    return n;
}

static int is_ld_var(const char *entry) {
    return strncmp(entry, "LD_LIBRARY_PATH=", 16) == 0
        || strncmp(entry, "LD_PRELOAD=", 11) == 0;
}

/*
 * Build envp with LD_LIBRARY_PATH and LD_PRELOAD restored.
 * The static buffers for the env entries are safe because execve either
 * succeeds (process replaced, buffers irrelevant) or fails (caller frees
 * the array immediately, buffers not referenced afterward).
 */
static char **envp_restore(char *const envp[]) {
    int n = envp_len(envp);
    int extra = (saved_lib_path[0] ? 1 : 0) + (saved_preload[0] ? 1 : 0);

    char **out = malloc((n + extra + 1) * sizeof(char *));
    if (!out) return NULL;

    int j = 0;
    for (int i = 0; i < n; i++) {
        if (!is_ld_var(envp[i]))
            out[j++] = envp[i];
    }

    static char llp_buf[sizeof(saved_lib_path) + 20];
    static char lp_buf[sizeof(saved_preload) + 20];

    if (saved_lib_path[0]) {
        snprintf(llp_buf, sizeof(llp_buf),
                 "LD_LIBRARY_PATH=%s", saved_lib_path);
        out[j++] = llp_buf;
    }
    if (saved_preload[0]) {
        snprintf(lp_buf, sizeof(lp_buf),
                 "LD_PRELOAD=%s", saved_preload);
        out[j++] = lp_buf;
    }

    out[j] = NULL;
    return out;
}

/* Build envp with LD_LIBRARY_PATH and LD_PRELOAD stripped. */
static char **envp_strip(char *const envp[]) {
    int n = envp_len(envp);
    char **out = malloc((n + 1) * sizeof(char *));
    if (!out) return NULL;

    int j = 0;
    for (int i = 0; i < n; i++) {
        if (!is_ld_var(envp[i]))
            out[j++] = envp[i];
    }
    out[j] = NULL;
    return out;
}

/* Call real_execve with a possibly-modified envp, then free it.
 * If new_envp is NULL, malloc failed — abort with ENOMEM. */
static int do_execve(const char *pathname, char *const argv[],
                     char *const envp[], char **new_envp) {
    if (!new_envp) {
        errno = ENOMEM;
        return -1;
    }
    int ret = real_execve(pathname, argv, new_envp);
    int e = errno;
    if (new_envp != (char **)envp) free(new_envp);
    errno = e;
    return ret;
}

/* ---------- exec* wrappers ---------- */

/*
 * execve(2) — the main interception point for explicit-envp calls.
 */
int execve(const char *pathname, char *const argv[], char *const envp[]) {
    if (!real_execve) {
        errno = ENOSYS;
        return -1;
    }

    if (is_self_reexec(pathname))
        return do_execve(pathname, argv, envp, envp_restore(envp));
    else
        return do_execve(pathname, argv, envp, envp_strip(envp));
}

/*
 * execv(3) — like execve but uses environ (already cleaned).
 * We intercept to handle self re-exec via this function.
 */
int execv(const char *pathname, char *const argv[]) {
    extern char **environ;
    return execve(pathname, argv, environ);
}

/*
 * execvp(3) — PATH resolution + environ.
 * For self re-exec with absolute path, delegate to our execve (which
 * restores LD vars).  For child processes, let glibc handle it — environ
 * is already clean so child inherits nothing.
 */
int execvp(const char *file, char *const argv[]) {
    if (file[0] == '/' && is_self_reexec(file)) {
        extern char **environ;
        return execve(file, argv, environ);
    }
    /* Non-self or relative path — glibc uses cleaned environ internally */
    if (!real_execvp) {
        errno = ENOSYS;
        return -1;
    }
    return real_execvp(file, argv);
}

/*
 * execvpe(3) — PATH resolution + explicit envp.
 */
int execvpe(const char *file, char *const argv[], char *const envp[]) {
    if (file[0] == '/' && is_self_reexec(file))
        return execve(file, argv, envp);

    if (!real_execvpe) {
        /* execvpe is a GNU extension; fall back to execve if available */
        if (file[0] == '/')
            return execve(file, argv, envp);
        errno = ENOSYS;
        return -1;
    }

    char **new_envp = envp_strip(envp);
    if (!new_envp) {
        errno = ENOMEM;
        return -1;
    }
    int ret = real_execvpe(file, argv, new_envp);
    int e = errno;
    if (new_envp != (char **)envp) free(new_envp);
    errno = e;
    return ret;
}
