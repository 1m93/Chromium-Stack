/*
 * ChromiumStack macOS bundle launcher.
 *
 * This exists only so that CFBundleExecutable is a real Mach-O binary. A shell
 * script works fine as a bundle executable until the project sits somewhere
 * TCC protects - ~/Documents, ~/Desktop, ~/Downloads - and then macOS attributes
 * the file access to /bin/bash instead of the app, denies it outright and never
 * shows the user a prompt. With a compiled executable the app has an identity of
 * its own, so macOS asks once and remembers the answer.
 *
 * All it does is chdir to the folder containing the .app and hand over to
 * gui.sh; every real decision still lives in the shell scripts.
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
             "display alert \"ChromiumStack could not start\" message \"%s\" as critical",
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

/* Contents/MacOS/ChromiumStack -> the folder holding ChromiumStack.app */
static int project_dir(char *out, size_t out_size)
{
    char raw[PATH_MAX];
    uint32_t size = sizeof(raw);
    if (_NSGetExecutablePath(raw, &size) != 0)
        return -1;

    char resolved[PATH_MAX];
    if (realpath(raw, resolved) == NULL)
        return -1;

    for (int level = 0; level < 4; level++) {
        char *slash = strrchr(resolved, '/');
        if (slash == NULL)
            return -1;
        *slash = '\0';
    }
    if (strlen(resolved) + 1 > out_size)
        return -1;
    strcpy(out, resolved);
    return 0;
}

/* Send the manager's output somewhere the user can be pointed at. Failing to
 * open the log is not fatal - starting the browser matters more. */
static void redirect_output(const char *project)
{
    const char *home_override = getenv("CHROMIUM_STACK_HOME");
    if (home_override == NULL)
        home_override = getenv("BROWSERS_EMU_HOME");
    char dir[PATH_MAX];
    if (home_override != NULL && home_override[0] != '\0') {
        snprintf(dir, sizeof(dir), "%s", home_override);
    } else {
        const char *home = getenv("HOME");
        if (home == NULL)
            return;
        snprintf(dir, sizeof(dir), "%s/.chromium-stack", home);
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
              "and allow chromium-stack, then open it again.\n\n"
              "Or run ./gui.sh from Terminal instead.");
        return 1;
    }

    if (access("gui.sh", X_OK) != 0) {
        alert("gui.sh is missing next to the app.\n\n"
              "Keep ChromiumStack.app inside the chromium-stack folder.");
        return 1;
    }

    redirect_output(project);

    execl("/bin/bash", "bash", "gui.sh", (char *)NULL);

    alert("Could not start gui.sh.");
    return 1;
}
