#include <dlfcn.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

int main(int argc, char *argv[]) {
	if (argc > 1 && strcmp(argv[1], "--version") == 0) {
		printf("test-foreign 1.0\n");
		return 0;
	}

	// Test self-exec: re-execute via /proc/self/exe
	if (argc > 1 && strcmp(argv[1], "--self-exec") == 0) {
		printf("self-exec: re-executing with --version\n");
		fflush(stdout);
		char *new_argv[] = {argv[0], "--version", NULL};
		execv("/proc/self/exe", new_argv);
		perror("execv");
		return 1;
	}

	// Test dlopen: load libz dynamically (not in ELF NEEDED)
	void *handle = dlopen("libz.so.1", RTLD_LAZY);
	if (!handle) {
		fprintf(stderr, "dlopen failed: %s\n", dlerror());
		return 1;
	}

	typedef const char *(*zlibVersion_t)(void);
	zlibVersion_t ver = (zlibVersion_t)dlsym(handle, "zlibVersion");
	if (!ver) {
		fprintf(stderr, "dlsym failed: %s\n", dlerror());
		dlclose(handle);
		return 1;
	}
	printf("dlopen: zlib %s\n", ver());
	dlclose(handle);

	printf("test-foreign: ok\n");
	return 0;
}
