/*
 * EngineShelf macOS bundle launcher.
 *
 * This exists only so that CFBundleExecutable is a real Mach-O binary. A shell
 * script works fine as a bundle executable until the project sits somewhere
 * TCC protects - ~/Documents, ~/Desktop, ~/Downloads - and then macOS attributes
 * the file access to /bin/bash instead of the app, denies it outright and never
 * shows the user a prompt. With a compiled executable the app has an identity of
 * its own, so macOS asks once and remembers the answer.
 *
 * It works in two layouts, trying them in order:
 *   1. Self-contained release - every script lives inside the bundle at
 *      Contents/Resources, so the .app is a single draggable thing.
 *   2. Development / sibling  - the scripts sit next to EngineShelf.app in the
 *      project folder, which is how the repo is laid out.
 * Whichever one has a runnable gui.sh wins.
 *
 * All it does is chdir to that folder and hand over to gui.sh; every real
 * decision still lives in the shell scripts.
 *
 * Build with tools/build-app.sh.
 */
#include <mach-o/dyld.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>

static void alert(const char *message)
{
    char script[2048];
    snprintf(script, sizeof(script),
             "display alert \"EngineShelf could not start\" message \"%s\" as critical",
             message);

    pid_t pid = fork();
    if (pid == 0) {
        execl("/usr/bin/osascript", "osascript", "-e", script, (char *)NULL);
        _exit(127);
    }
    if (pid > 0) {
        int status;
        waitpid(pid, &status, 0);
    }
}

/* The resolved path of this executable:
 *   <bundle>/EngineShelf.app/Contents/MacOS/EngineShelf   */
static int executable_path(char *out, size_t out_size)
{
    char raw[PATH_MAX];
    uint32_t size = sizeof(raw);
    if (_NSGetExecutablePath(raw, &size) != 0)
        return -1;
    if (realpath(raw, out) == NULL)
        return -1;
    if (strlen(out) >= out_size)
        return -1;
    return 0;
}

/* Strip `levels` trailing path components from `path`, in place. */
static int strip_levels(char *path, int levels)
{
    for (int level = 0; level < levels; level++) {
        char *slash = strrchr(path, '/');
        if (slash == NULL)
            return -1;
        *slash = '\0';
    }
    return 0;
}

/* True if `dir/gui.sh` exists and is executable. */
static int has_launcher(const char *dir)
{
    char probe[PATH_MAX];
    if ((size_t)snprintf(probe, sizeof(probe), "%s/gui.sh", dir) >= sizeof(probe))
        return 0;
    return access(probe, X_OK) == 0;
}

/* Pick the folder that holds gui.sh: the bundle's own Resources first (a
 * self-contained release), then the folder next to the .app (the repo). */
static int project_dir(char *out, size_t out_size)
{
    char exe[PATH_MAX];
    if (executable_path(exe, sizeof(exe)) != 0)
        return -1;

    /* Contents/MacOS/EngineShelf -> Contents/Resources */
    char resources[PATH_MAX];
    if ((size_t)snprintf(resources, sizeof(resources), "%s", exe) < sizeof(resources) &&
        strip_levels(resources, 2) == 0) {
        char joined[PATH_MAX];
        if ((size_t)snprintf(joined, sizeof(joined), "%s/Resources", resources) < sizeof(joined) &&
            has_launcher(joined)) {
            if (strlen(joined) + 1 > out_size)
                return -1;
            strcpy(out, joined);
            return 0;
        }
    }

    /* Contents/MacOS/EngineShelf -> the folder holding EngineShelf.app */
    char sibling[PATH_MAX];
    if ((size_t)snprintf(sibling, sizeof(sibling), "%s", exe) >= sizeof(sibling) ||
        strip_levels(sibling, 4) != 0)
        return -1;
    if (strlen(sibling) + 1 > out_size)
        return -1;
    strcpy(out, sibling);
    return 0;
}

/* Send the manager's output somewhere the user can be pointed at. Failing to
 * open the log is not fatal - starting the browser matters more. */
static void redirect_output(const char *project)
{
    const char *home_override = getenv("ENGINESHELF_HOME");
    if (home_override == NULL)
        home_override = getenv("BROWSERS_EMU_HOME");
    char dir[PATH_MAX];
    if (home_override != NULL && home_override[0] != '\0') {
        snprintf(dir, sizeof(dir), "%s", home_override);
    } else {
        const char *home = getenv("HOME");
        if (home == NULL)
            return;
        snprintf(dir, sizeof(dir), "%s/.engineshelf", home);
    }
    mkdir(dir, 0755);

    char log[PATH_MAX];
    snprintf(log, sizeof(log), "%s/manager.log", dir);
    FILE *handle = freopen(log, "a", stdout);
    if (handle != NULL)
        dup2(fileno(stdout), fileno(stderr));
    (void)project;
}

int main(void)
{
    char project[PATH_MAX];
    if (project_dir(project, sizeof(project)) != 0) {
        alert("Could not work out where the app lives.");
        return 1;
    }

    if (chdir(project) != 0) {
        /* The usual cause is macOS withholding access to the enclosing folder. */
        alert("macOS is blocking access to the folder this app is in.\n\n"
              "Open System Settings > Privacy & Security > Files and Folders "
              "and allow EngineShelf, then open it again.\n\n"
              "Or run ./gui.sh from Terminal instead.");
        return 1;
    }

    if (access("gui.sh", X_OK) != 0) {
        alert("gui.sh is missing.\n\n"
              "Keep EngineShelf.app inside the engineshelf folder, "
              "or use the packaged release.");
        return 1;
    }

    redirect_output(project);

    execl("/bin/bash", "bash", "gui.sh", (char *)NULL);

    alert("Could not start gui.sh.");
    return 1;
}
