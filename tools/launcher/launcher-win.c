/*
 * ChromiumStack Windows launcher.
 *
 * This exists for the same reason as the macOS bundle launcher: so that
 * double-clicking the project looks like opening an application. A .bat file
 * cannot carry an icon - Explorer shows it as a script, and Windows warns about
 * running it more loudly than it does about a program - so the icon has to be
 * embedded in a real executable. See launcher-win.rc for that resource.
 *
 * It is deliberately a console program rather than a windowed one. The manager
 * has no quit button, so the console window is the off switch: closing it stops
 * the manager, exactly as the .bat and gui.sh do. Hiding the window would leave
 * Task Manager as the only way to stop it.
 *
 * All it does is chdir to the folder holding it and hand over to gui.ps1, with
 * -ExecutionPolicy Bypass so an unconfigured machine does not refuse the script;
 * every real decision still lives in the PowerShell scripts. Arguments are
 * passed straight through, so ChromiumStack.exe -Port 8080 works.
 *
 * Build with tools/build-exe.sh.
 */
#include <windows.h>
#include <stdio.h>
#include <wchar.h>

#define CMD_MAX 32768

/* Double-clicked from Explorer, the console dies with the process and an error
 * message with it. Hold the window open so it can be read. */
static void fail(const wchar_t *message)
{
    fwprintf(stderr, L"\n  ChromiumStack could not start.\n\n  %ls\n\n", message);
    fwprintf(stderr, L"  Press Enter to close.\n");
    (void)getchar();
}

/* ...\ChromiumStack.exe -> the folder holding it */
static int project_dir(wchar_t *out, size_t count)
{
    DWORD written = GetModuleFileNameW(NULL, out, (DWORD)count);
    if (written == 0 || written >= count)
        return -1;

    wchar_t *slash = wcsrchr(out, L'\\');
    if (slash == NULL)
        return -1;
    *slash = L'\0';
    return 0;
}

/* Windows 10/11 always has PowerShell 5.1 here. Spelling the path out rather
 * than trusting PATH means a broken PATH cannot turn into a confusing error. */
static int powershell_path(wchar_t *out, size_t count)
{
    static const wchar_t *tail = L"\\WindowsPowerShell\\v1.0\\powershell.exe";
    UINT written = GetSystemDirectoryW(out, (UINT)count);
    if (written == 0 || written >= count)
        return -1;
    if (wcslen(out) + wcslen(tail) + 1 > count)
        return -1;
    wcscat(out, tail);
    return 0;
}

static int append(wchar_t *command, const wchar_t *text)
{
    if (wcslen(command) + wcslen(text) + 1 > CMD_MAX)
        return -1;
    wcscat(command, text);
    return 0;
}

/* Quote every argument. gui.ps1 takes -Port and -NoOpen, neither of which needs
 * anything cleverer, and quoting unconditionally keeps a path with a space in it
 * from arriving as two arguments. */
static int append_argument(wchar_t *command, const wchar_t *argument)
{
    if (wcschr(argument, L'"') != NULL)
        return -1;
    return append(command, L" \"") || append(command, argument) || append(command, L"\"");
}

int wmain(int argc, wchar_t **argv)
{
    wchar_t project[MAX_PATH];
    if (project_dir(project, MAX_PATH) != 0) {
        fail(L"Could not work out where this program lives.");
        return 1;
    }

    if (!SetCurrentDirectoryW(project)) {
        fail(L"Could not enter the folder this program is in.");
        return 1;
    }

    if (GetFileAttributesW(L"gui.ps1") == INVALID_FILE_ATTRIBUTES) {
        fail(L"gui.ps1 is missing next to this program.\n\n"
             L"  Keep ChromiumStack.exe inside the chromium-stack folder.");
        return 1;
    }

    wchar_t powershell[MAX_PATH];
    if (powershell_path(powershell, MAX_PATH) != 0) {
        fail(L"Could not find powershell.exe in the system directory.");
        return 1;
    }

    static wchar_t command[CMD_MAX];
    command[0] = L'\0';
    int overflow = append(command, L"\"") || append(command, powershell) ||
                   append(command, L"\" -NoProfile -ExecutionPolicy Bypass -File \"") ||
                   append(command, project) || append(command, L"\\gui.ps1\"");
    for (int i = 1; i < argc && !overflow; i++)
        overflow = append_argument(command, argv[i]);
    if (overflow) {
        fail(L"Too many arguments, or an argument containing a quote.");
        return 1;
    }

    SetConsoleTitleW(L"ChromiumStack");
    wprintf(L"\n  Starting the ChromiumStack manager.\n");
    wprintf(L"  Close this window to stop it. Browsers it launched keep running.\n\n");
    fflush(stdout);

    STARTUPINFOW startup = { .cb = sizeof(startup) };
    PROCESS_INFORMATION process = { 0 };
    if (!CreateProcessW(powershell, command, NULL, NULL, TRUE, 0, NULL, project,
                        &startup, &process)) {
        fail(L"Could not start PowerShell.");
        return 1;
    }

    /* Wait, so closing the console takes the manager with it and the exit code
     * belongs to the script rather than to this wrapper. */
    WaitForSingleObject(process.hProcess, INFINITE);

    DWORD status = 1;
    GetExitCodeProcess(process.hProcess, &status);
    CloseHandle(process.hProcess);
    CloseHandle(process.hThread);

    /* Matches ChromiumStack.bat's `if errorlevel 1 pause`: a failure that scrolls
     * past unread is a bug report nobody can answer. */
    if (status != 0) {
        fwprintf(stderr, L"\n  The manager exited with status %lu.\n", status);
        fwprintf(stderr, L"  Press Enter to close.\n");
        (void)getchar();
    }
    return (int)status;
}
