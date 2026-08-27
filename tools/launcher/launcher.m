/*
 * EngineShelf macOS app.
 *
 * The manager is a local web page, and something has to hold the window it is
 * drawn in. That used to be Chrome, started with --app and its own profile
 * directory, and it never behaved like an app: the Dock icon belonged to Chrome,
 * so pressing it woke Chrome rather than the manager - and Chrome, finding no
 * window of its own visible, answered by opening an ordinary New Tab window on
 * google.com. A window parked in Stage Manager could not be got back at all.
 *
 * So the window belongs to this bundle now. It is an ordinary Cocoa app with a
 * WKWebView filling it: the Dock icon is EngineShelf's, pressing it brings the
 * manager back (applicationShouldHandleReopen: below is the whole point),
 * Stage Manager and Cmd-Tab treat it like any other app, and there is no second
 * browser profile on disk at all.
 *
 * The server is still gui.sh - started with --no-open, because this process is
 * the window it would otherwise have opened. Every real decision still lives in
 * the shell scripts; this file starts one, shows what it serves, and shuts it
 * down again when the window closes.
 *
 * A compiled binary is also what CFBundleExecutable has to be. A shell script
 * works as one until the project sits somewhere TCC protects - ~/Documents,
 * ~/Desktop, ~/Downloads - and then macOS attributes the file access to
 * /bin/bash instead of the app, denies it outright and never asks. With a
 * binary the app has an identity of its own, so macOS asks once and remembers.
 *
 * It works in two layouts, trying them in order:
 *   1. Self-contained release - every script lives inside the bundle at
 *      Contents/Resources, so the .app is a single draggable thing.
 *   2. Development / sibling  - the scripts sit next to EngineShelf.app in the
 *      project folder, which is how the repo is laid out.
 * Whichever one has a runnable gui.sh wins.
 *
 * Build with tools/build-app.sh.
 */
#import <Cocoa/Cocoa.h>
#import <WebKit/WebKit.h>

#include <fcntl.h>
#include <limits.h>
#include <mach-o/dyld.h>
#include <signal.h>
#include <stdio.h>
#include <string.h>
#include <spawn.h>
#include <sys/wait.h>
#include <unistd.h>

extern char **environ;

/* How long the manager gets to print the address it is serving on before this
 * is reported as a failure to start. It runs the CLI once first, and a cold
 * catalog read on a slow disk is not instant. */
static const NSTimeInterval kStartupLimit = 90.0;

static NSString *home_dir(void);

/* Anything the app says goes to the same log the manager writes, whether or not
 * anyone is there to click the panel away: launched from the Dock there is no
 * terminal, and a failure that only ever existed as a dismissed dialog is a
 * failure nobody can report. */
/* O_APPEND, not seek-to-end: the manager writes to this file through the pipe
 * this app forwards, and a remembered offset from two writers loses lines. */
static void append_to_log(NSData *data)
{
    NSString *home = home_dir();
    [NSFileManager.defaultManager createDirectoryAtPath:home
                            withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *path = [home stringByAppendingPathComponent:@"manager.log"];
    int handle = open(path.fileSystemRepresentation,
                      O_WRONLY | O_APPEND | O_CREAT, 0644);
    if (handle < 0)
        return;
    write(handle, data.bytes, data.length);
    close(handle);
}

static void note(NSString *message)
{
    NSString *line = [NSString stringWithFormat:@"  %@\n", message];
    append_to_log([line dataUsingEncoding:NSUTF8StringEncoding]);
}

static void alert(NSString *message)
{
    note(message);
    NSAlert *panel = [[NSAlert alloc] init];
    panel.alertStyle = NSAlertStyleCritical;
    panel.messageText = @"EngineShelf could not start";
    panel.informativeText = message;
    [panel runModal];
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

/* Where the manager keeps its files, and so where its log goes. The same two
 * overrides the shell scripts read, in the same order. */
static NSString *home_dir(void)
{
    NSDictionary *env = NSProcessInfo.processInfo.environment;
    for (NSString *name in @[@"ENGINESHELF_HOME", @"BROWSERS_EMU_HOME"]) {
        NSString *value = env[name];
        if (value.length > 0)
            return value;
    }
    return [NSHomeDirectory() stringByAppendingPathComponent:@".engineshelf"];
}


#pragma mark -

/* NSApplication holds its delegate weakly, and the local that used to own this
 * was released as soon as it had been handed over - so the delegate went with
 * it, taking the pipe reader with it: the manager printed its address into a
 * pipe nobody was reading any more, and the window sat on "Starting the
 * manager" for ever while a perfectly good server ran behind it. The app owns
 * its delegate for as long as the app runs, and this is where that is said. */
@interface Manager : NSObject <NSApplicationDelegate, NSWindowDelegate,
                               WKNavigationDelegate, WKUIDelegate>
@property (nonatomic, copy)   NSString *project;
/* Every window is the same manager seen twice: one shelf, one server, two
 * views of it - the same thing the Chrome-hosted window on Linux and Windows
 * gets by being launched again. The app quits when the last one closes. */
@property (nonatomic, strong) NSMutableArray<NSWindow *> *windows;
@property (nonatomic, assign) pid_t server;      /* the manager, 0 once it has gone */
@property (nonatomic, strong) dispatch_source_t watch;
@property (nonatomic, copy)   NSString *address;
/* The manager was already running when this launch happened, so the server is
 * not this app's to stop when the window closes. */
@property (nonatomic, assign) BOOL adopted;
@property (nonatomic, assign) BOOL closing;
@end

@implementation Manager
{
    NSMutableString *_pending;  /* server output not yet split into lines */
    NSLock *_pendingLock;
}

- (void)dealloc
{
    /* Nothing should ever release this while the app is running; if something
     * does, the log is where the next hour of confusion gets saved. */
    note(@"(the window controller went away)");
}

- (instancetype)initWithProject:(NSString *)project
{
    self = [super init];
    if (self) {
        _project = [project copy];
        _windows = [NSMutableArray array];
        _pending = [NSMutableString string];
        _pendingLock = [[NSLock alloc] init];
    }
    return self;
}

#pragma mark window

- (void)applicationDidFinishLaunching:(NSNotification *)note
{
    [self buildMenu];
    [self buildWindow];
    [self startServer];
    [self failIfSilent];
}

- (void)buildWindow
{
    [self openWindow:nil];
}

/* Also the Cmd-N action. A second window is another view of the same server:
 * the shelf in one and the year grid in the other, or a download watched in one
 * while the other is being read. */
- (void)openWindow:(id)sender
{
    NSRect frame = NSMakeRect(0, 0, 1440, 920);
    NSWindow *window = [[NSWindow alloc]
        initWithContentRect:frame
                  styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                             NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable)
                    backing:NSBackingStoreBuffered
                      defer:NO];
    window.title = @"EngineShelf";
    window.delegate = self;
    window.releasedWhenClosed = NO;
    /* 900x620 is about where the shelf stops being able to show a row's
     * actions; below that the page is honest but cramped. */
    window.minSize = NSMakeSize(900, 620);

    if (self.windows.count == 0) {
        [window center];
        /* Remembered per user, so the first window comes back where it was
         * left. The ones after it are stacked off it instead, which is what
         * every other app does with a second window. */
        [window setFrameAutosaveName:@"EngineShelfWindow"];
    } else {
        NSWindow *last = self.windows.lastObject;
        [window setFrame:last.frame display:NO];
        [window cascadeTopLeftFromPoint:
            NSMakePoint(NSMinX(last.frame) + 26, NSMaxY(last.frame) - 26)];
    }

    WKWebView *web = [[WKWebView alloc] initWithFrame:window.contentView.bounds
                                       configuration:[[WKWebViewConfiguration alloc] init]];
    web.identifier = @"web";
    web.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    web.navigationDelegate = self;
    web.UIDelegate = self;
    /* The page paints its own background a moment later; matching its dark
     * ground here is what stops a white flash on every launch. */
    web.hidden = YES;
    [window.contentView setWantsLayer:YES];
    window.contentView.layer.backgroundColor =
        [NSColor colorWithSRGBRed:0.06 green:0.07 blue:0.09 alpha:1].CGColor;
    [window.contentView addSubview:web];

    NSTextField *notice = [NSTextField labelWithString:@"Starting the manager…"];
    notice.identifier = @"notice";
    notice.textColor = [NSColor secondaryLabelColor];
    notice.alignment = NSTextAlignmentCenter;
    notice.frame = NSMakeRect(0, NSMidY(frame) - 12, NSWidth(frame), 24);
    notice.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin | NSViewMaxYMargin;
    [window.contentView addSubview:notice];

    [self.windows addObject:window];
    note([NSString stringWithFormat:@"Window opened (%lu open).",
          (unsigned long)self.windows.count]);
    [window makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];

    /* A window opened after the address is known has nothing to wait for. */
    if (self.address)
        [web loadRequest:[NSURLRequest requestWithURL:[NSURL URLWithString:self.address]]];
}

/* The Dock does not read the File menu: an app that wants "New Window" on its
 * Dock icon has to hand the Dock a menu saying so. Items here are dispatched
 * straight to their target rather than through the responder chain, which is
 * why this one names it. */
- (NSMenu *)applicationDockMenu:(NSApplication *)app
{
    NSMenu *menu = [[NSMenu alloc] init];
    NSMenuItem *item = [menu addItemWithTitle:@"New Window"
                                       action:@selector(openWindow:)
                                keyEquivalent:@""];
    item.target = self;
    return menu;
}

- (NSView *)viewNamed:(NSString *)name in:(NSWindow *)window
{
    for (NSView *view in window.contentView.subviews)
        if ([view.identifier isEqualToString:name])
            return view;
    return nil;
}

- (WKWebView *)webIn:(NSWindow *)window
{
    return (WKWebView *)[self viewNamed:@"web" in:window];
}

- (NSTextField *)noticeIn:(NSWindow *)window
{
    return (NSTextField *)[self viewNamed:@"notice" in:window];
}

/* Something has happened to the manager itself, so it belongs in front of every
 * window rather than whichever one happens to be in front. */
- (void)noticeEverywhere:(NSString *)text
{
    for (NSWindow *window in self.windows) {
        [self noticeIn:window].stringValue = text;
        [self noticeIn:window].hidden = NO;
        [self webIn:window].hidden = YES;
    }
}

- (NSWindow *)frontWindow
{
    for (NSWindow *window in self.windows)
        if (window.isKeyWindow)
            return window;
    return self.windows.lastObject;
}

/* Without a menu of its own an app built this way has no Cmd-Q, no Cmd-W and -
 * the one people notice - no Cmd-C in the page's own text fields, because the
 * standard editing commands are dispatched through the menu. */
- (void)buildMenu
{
    NSMenu *bar = [[NSMenu alloc] init];

    NSMenuItem *appItem = [[NSMenuItem alloc] init];
    NSMenu *appMenu = [[NSMenu alloc] init];
    [appMenu addItemWithTitle:@"About EngineShelf"
                       action:@selector(orderFrontStandardAboutPanel:) keyEquivalent:@""];
    [appMenu addItem:[NSMenuItem separatorItem]];
    [appMenu addItemWithTitle:@"Hide EngineShelf" action:@selector(hide:) keyEquivalent:@"h"];
    [[appMenu addItemWithTitle:@"Hide Others" action:@selector(hideOtherApplications:)
                 keyEquivalent:@"h"] setKeyEquivalentModifierMask:
        NSEventModifierFlagCommand | NSEventModifierFlagOption];
    [appMenu addItemWithTitle:@"Show All" action:@selector(unhideAllApplications:) keyEquivalent:@""];
    [appMenu addItem:[NSMenuItem separatorItem]];
    [appMenu addItemWithTitle:@"Quit EngineShelf" action:@selector(terminate:) keyEquivalent:@"q"];
    appItem.submenu = appMenu;
    [bar addItem:appItem];

    NSMenuItem *fileItem = [[NSMenuItem alloc] init];
    NSMenu *fileMenu = [[NSMenu alloc] initWithTitle:@"File"];
    [fileMenu addItemWithTitle:@"New Window" action:@selector(openWindow:) keyEquivalent:@"n"];
    [fileMenu addItemWithTitle:@"Close" action:@selector(performClose:) keyEquivalent:@"w"];
    fileItem.submenu = fileMenu;
    [bar addItem:fileItem];

    NSMenuItem *editItem = [[NSMenuItem alloc] init];
    NSMenu *editMenu = [[NSMenu alloc] initWithTitle:@"Edit"];
    [editMenu addItemWithTitle:@"Undo" action:@selector(undo:) keyEquivalent:@"z"];
    [[editMenu addItemWithTitle:@"Redo" action:@selector(redo:) keyEquivalent:@"z"]
        setKeyEquivalentModifierMask:NSEventModifierFlagCommand | NSEventModifierFlagShift];
    [editMenu addItem:[NSMenuItem separatorItem]];
    [editMenu addItemWithTitle:@"Cut" action:@selector(cut:) keyEquivalent:@"x"];
    [editMenu addItemWithTitle:@"Copy" action:@selector(copy:) keyEquivalent:@"c"];
    [editMenu addItemWithTitle:@"Paste" action:@selector(paste:) keyEquivalent:@"v"];
    [editMenu addItemWithTitle:@"Select All" action:@selector(selectAll:) keyEquivalent:@"a"];
    editItem.submenu = editMenu;
    [bar addItem:editItem];

    NSMenuItem *viewItem = [[NSMenuItem alloc] init];
    NSMenu *viewMenu = [[NSMenu alloc] initWithTitle:@"View"];
    [editMenu setTitle:@"Edit"];
    [viewMenu addItemWithTitle:@"Reload" action:@selector(reloadPage:) keyEquivalent:@"r"];
    [viewMenu addItem:[NSMenuItem separatorItem]];
    [viewMenu addItemWithTitle:@"Actual Size" action:@selector(zoomReset:) keyEquivalent:@"0"];
    [viewMenu addItemWithTitle:@"Zoom In" action:@selector(zoomIn:) keyEquivalent:@"+"];
    [viewMenu addItemWithTitle:@"Zoom Out" action:@selector(zoomOut:) keyEquivalent:@"-"];
    viewItem.submenu = viewMenu;
    [bar addItem:viewItem];

    NSMenuItem *windowItem = [[NSMenuItem alloc] init];
    NSMenu *windowMenu = [[NSMenu alloc] initWithTitle:@"Window"];
    [windowMenu addItemWithTitle:@"Minimise" action:@selector(performMiniaturize:) keyEquivalent:@"m"];
    [windowMenu addItemWithTitle:@"Bring All to Front"
                          action:@selector(arrangeInFront:) keyEquivalent:@""];
    windowItem.submenu = windowMenu;
    [bar addItem:windowItem];

    NSApp.mainMenu = bar;
    NSApp.windowsMenu = windowMenu;
}

- (void)reloadPage:(id)sender { [[self webIn:self.frontWindow] reload]; }

/* Page zoom arrived in macOS 11; on anything older the commands are there and
 * do nothing, which is better than a bundle that will not load at all. */
- (void)zoomBy:(CGFloat)factor
{
    if (@available(macOS 11.0, *)) {
        WKWebView *web = [self webIn:self.frontWindow];
        CGFloat next = factor == 0 ? 1.0 : web.pageZoom * factor;
        web.pageZoom = MIN(MAX(next, 0.5), 3.0);
    }
}

- (void)zoomReset:(id)sender { [self zoomBy:0]; }
- (void)zoomIn:(id)sender    { [self zoomBy:1.1]; }
- (void)zoomOut:(id)sender   { [self zoomBy:1.0 / 1.1]; }

#pragma mark the server

- (void)startServer
{
    /* posix_spawn rather than NSTask, and rather than fork: NSTask reads the
     * working directory as it starts, and when the project sits in ~/Documents
     * that read goes through TCC - which, asked from inside
     * applicationDidFinishLaunching, never came back. A hand-rolled fork is no
     * better: this process has AppKit and WebKit up, and a forked child that
     * touches anything before exec can deadlock against them. posix_spawn does
     * the whole thing in one call and inherits the working directory main()
     * already moved to. */
    char owner[32];
    snprintf(owner, sizeof(owner), "%d", getpid());

    int fds[2];
    if (pipe(fds) != 0) {
        alert(@"Could not open a pipe to the manager.");
        [NSApp terminate:nil];
        return;
    }

    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);
    posix_spawn_file_actions_addclose(&actions, fds[0]);
    posix_spawn_file_actions_adddup2(&actions, fds[1], STDOUT_FILENO);
    posix_spawn_file_actions_adddup2(&actions, fds[1], STDERR_FILENO);
    posix_spawn_file_actions_addclose(&actions, fds[1]);
    posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0);

    /* Its own process group, so one signal reaches the whole of it. */
    posix_spawnattr_t attributes;
    posix_spawnattr_init(&attributes);
    posix_spawnattr_setflags(&attributes, POSIX_SPAWN_SETPGROUP);
    posix_spawnattr_setpgroup(&attributes, 0);

    /* --no-open because this process is the window it would have opened, and
     * --owner-pid so a manager whose app is killed outright does not go on
     * serving with nothing to show for it. */
    /* Through this binary a second time rather than straight to /bin/bash.
     * bash is one of Apple's own, and a child that is one of Apple's own
     * answers to TCC as itself rather than as the app that started it: asked
     * for a file in ~/Documents it waits on a decision that has no window to
     * ask through, and hangs there for ever. Started as a copy of this binary
     * the child belongs to the app, and keeps belonging to it across the exec
     * into bash below - which is exactly how the old launcher, which was
     * nothing but that exec, could read the project at all. */
    char binary[PATH_MAX];
    if (executable_path(binary, sizeof(binary)) != 0) {
        close(fds[0]);
        close(fds[1]);
        alert(@"Could not work out where the app lives.");
        [NSApp terminate:nil];
        return;
    }
    char *argv[] = {binary, (char *)"--serve", (char *)"--owner-pid", owner, NULL};
    pid_t child = 0;
    int failed = posix_spawn(&child, binary, &actions, &attributes, argv, environ);
    posix_spawn_file_actions_destroy(&actions);
    posix_spawnattr_destroy(&attributes);

    if (failed != 0) {
        close(fds[0]);
        close(fds[1]);
        alert([NSString stringWithFormat:@"Could not start gui.sh (%s).", strerror(failed)]);
        [NSApp terminate:nil];
        return;
    }

    close(fds[1]);
    self.server = child;

    /* A thread of its own on a blocking read, rather than NSFileHandle's
     * readabilityHandler: that handler quietly never fired here, and a manager
     * printing its address into a pipe nobody reads is a window that says
     * "Starting" for ever. read() on a pipe is the one thing that cannot be
     * subtle about it. */
    __weak Manager *weakSelf = self;
    int reader = fds[0];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        char buffer[4096];
        for (;;) {
            ssize_t got = read(reader, buffer, sizeof(buffer));
            if (got <= 0)
                break;  /* the manager has closed its end, or is gone */
            Manager *strong = weakSelf;
            if (!strong)
                break;
            [strong tookOutput:[NSData dataWithBytes:buffer length:(NSUInteger)got]];
        }
        close(reader);
    });

    /* Deliberately not the main queue. A block on the main queue cannot run
     * while another one is still on it, and AppKit spins nested run loops
     * inside main-queue blocks - a modal panel, or applicationShouldTerminate
     * answering "later". Anything queued that way waits for the outer block to
     * finish, which is how this app came to sit on "Starting the manager" with
     * the address already read, and how "Closing" could never finish. Every
     * hand-off below goes through the run loop instead, which nested loops do
     * service. */
    self.watch = dispatch_source_create(
        DISPATCH_SOURCE_TYPE_PROC, (uintptr_t)child, DISPATCH_PROC_EXIT,
        dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
    dispatch_source_set_event_handler(self.watch, ^{
        Manager *strong = weakSelf;
        if (!strong)
            return;
        int status = 0;
        waitpid(child, &status, WNOHANG);
        strong.server = 0;
        dispatch_source_cancel(strong.watch);
        [strong performSelectorOnMainThread:@selector(serverEndedWith:)
                                withObject:@(WIFEXITED(status) ? WEXITSTATUS(status) : -1)
                             waitUntilDone:NO];
    });
    dispatch_resume(self.watch);
}

/* Everything the manager prints goes to its log, as it did when a terminal or
 * the old launcher owned that output. The one line read rather than filed is
 * the address: both the manager that starts and the one that says another is
 * already running print it, and either is the page to show. */
- (void)tookOutput:(NSData *)chunk
{
    append_to_log(chunk);

    NSString *text = [[NSString alloc] initWithData:chunk encoding:NSUTF8StringEncoding];
    if (text.length == 0)
        return;

    [_pendingLock lock];
    [_pending appendString:text];
    NSString *whole = [_pending copy];
    NSRange lastBreak = [whole rangeOfString:@"\n" options:NSBackwardsSearch];
    if (lastBreak.location != NSNotFound) {
        [_pending setString:[whole substringFromIndex:NSMaxRange(lastBreak)]];
        whole = [whole substringToIndex:NSMaxRange(lastBreak)];
    } else {
        whole = @"";
    }
    [_pendingLock unlock];

    for (NSString *line in [whole componentsSeparatedByString:@"\n"]) {
        if ([line containsString:@"is already running"])
            self.adopted = YES;
        NSRange found = [line rangeOfString:@"http://127.0.0.1:"];
        if (found.location == NSNotFound)
            continue;
        NSString *address = [line substringFromIndex:found.location];
        address = [address stringByTrimmingCharactersInSet:
                   NSCharacterSet.whitespaceAndNewlineCharacterSet];
        [self performSelectorOnMainThread:@selector(show:) withObject:address
                            waitUntilDone:NO];
    }
}

- (void)show:(NSString *)address
{
    if (self.address)
        return;
    self.address = address;
    note([NSString stringWithFormat:@"Window loading %@", address]);
    NSURL *url = [NSURL URLWithString:address];
    if (!url) {
        alert([NSString stringWithFormat:@"The manager reported an address this "
                                          "window cannot open:\n\n%@", address]);
        [NSApp terminate:nil];
        return;
    }
    for (NSWindow *window in self.windows)
        [[self webIn:window] loadRequest:[NSURLRequest requestWithURL:url]];
}

- (void)serverEndedWith:(NSNumber *)status
{
    if (self.closing)
        return;  /* On the way out already; the window is going with it. */
    if (self.adopted)
        return;  /* It only printed where the real manager is and stepped aside. */

    /* Said in the window rather than in a panel that has to be clicked, and the
     * app stays up: an alert on a background app is a dialog nobody sees, and
     * quitting from here is what used to strand the app mid-terminate. */
    note([NSString stringWithFormat:@"The manager stopped (exit %@).", status]);
    [self noticeEverywhere:
        self.address
            ? @"The manager stopped. Its last words are in manager.log, in the "
               "EngineShelf home directory. Close this window and open EngineShelf again."
            : [NSString stringWithFormat:
               @"The manager could not start (exit %@). The reason is in manager.log, "
                "in the EngineShelf home directory.", status]];
}

/* A manager that never says where it is serving is a manager that is not
 * coming, and a window sitting on "Starting…" for ever says nothing useful. */
- (void)failIfSilent
{
    /* An NSTimer, not dispatch_after: this has to be able to fire while the
     * main queue is busy, and it must not be the thing that decides to quit -
     * a window saying what happened is more use than an app that vanishes. */
    [NSTimer scheduledTimerWithTimeInterval:kStartupLimit repeats:NO block:^(NSTimer *unused) {
        (void)unused;
        if (self.address || self.closing)
            return;
        note(@"The manager has not printed an address yet.");
        [self noticeEverywhere:
            @"The manager has not answered. What it managed to say is in manager.log, "
             "in the EngineShelf home directory."];
    }];
}

#pragma mark the page

- (void)webView:(WKWebView *)web didFinishNavigation:(WKNavigation *)navigation
{
    NSTextField *notice = [self noticeIn:web.window];
    if (notice.hidden == NO)
        note(@"Window showing the manager.");
    notice.hidden = YES;
    web.hidden = NO;
}

- (void)webView:(WKWebView *)web
    didFailProvisionalNavigation:(WKNavigation *)navigation
                       withError:(NSError *)error
{
    note([NSString stringWithFormat:@"Window could not load: %@", error.localizedDescription]);
    NSTextField *notice = [self noticeIn:web.window];
    notice.stringValue = [NSString stringWithFormat:@"Cannot reach the manager: %@",
                          error.localizedDescription];
    notice.hidden = NO;
    web.hidden = YES;
}

/* The manager is a local page and everything it links to that is not local -
 * a container's noVNC desktop, a page on the web - belongs in the user's own
 * browser, with their session and their bookmarks, not in this window. */
- (void)webView:(WKWebView *)web
    decidePolicyForNavigationAction:(WKNavigationAction *)action
                    decisionHandler:(void (^)(WKNavigationActionPolicy))decide
{
    NSURL *url = action.request.URL;
    BOOL local = [url.host isEqualToString:@"127.0.0.1"] || [url.host isEqualToString:@"localhost"];
    if (local || url == nil) {
        decide(WKNavigationActionPolicyAllow);
        return;
    }
    [NSWorkspace.sharedWorkspace openURL:url];
    decide(WKNavigationActionPolicyCancel);
}

/* window.open, and any link with target=_blank: the same rule, except that a
 * container's desktop is on 127.0.0.1 too and still wants its own window. */
- (WKWebView *)webView:(WKWebView *)web
    createWebViewWithConfiguration:(WKWebViewConfiguration *)configuration
               forNavigationAction:(WKNavigationAction *)action
                    windowFeatures:(WKWindowFeatures *)features
{
    if (action.request.URL)
        [NSWorkspace.sharedWorkspace openURL:action.request.URL];
    return nil;
}

- (void)webView:(WKWebView *)web
    runJavaScriptAlertPanelWithMessage:(NSString *)message
                      initiatedByFrame:(WKFrameInfo *)frame
                     completionHandler:(void (^)(void))done
{
    NSAlert *panel = [[NSAlert alloc] init];
    panel.messageText = @"EngineShelf";
    panel.informativeText = message;
    [panel runModal];
    done();
}

- (void)webView:(WKWebView *)web
    runJavaScriptConfirmPanelWithMessage:(NSString *)message
                        initiatedByFrame:(WKFrameInfo *)frame
                       completionHandler:(void (^)(BOOL))done
{
    NSAlert *panel = [[NSAlert alloc] init];
    panel.messageText = @"EngineShelf";
    panel.informativeText = message;
    [panel addButtonWithTitle:@"OK"];
    [panel addButtonWithTitle:@"Cancel"];
    done([panel runModal] == NSAlertFirstButtonReturn);
}

#pragma mark closing

/* Closing the LAST window ends the session - the server stops, the browsers it
 * launched close, the containers it started come down - which is the point, but
 * not something a stray click on the red button should do while a download is
 * halfway through. In a browser the page guards this with beforeunload; here
 * the question is asked properly, in an alert this app owns.
 *
 * Any other window is just a second view of the same shelf, and closing one of
 * those is not worth a question. */
- (BOOL)windowShouldClose:(NSWindow *)sender
{
    if (self.closing || !self.address || self.windows.count > 1)
        return YES;

    [[self webIn:sender] evaluateJavaScript:
        @"(function(){try{var r=window.engineShelfRunning();"
         "return r.browsers+r.containers+r.jobs}catch(e){return 0}})()"
               completionHandler:^(id result, NSError *jsError) {
        (void)jsError;
        long busy = [result respondsToSelector:@selector(longValue)] ? [result longValue] : 0;
        if (busy > 0) {
            NSAlert *panel = [[NSAlert alloc] init];
            panel.messageText = @"Close EngineShelf?";
            /* The window is the session, so this is the app going, not a tab. */
            panel.informativeText =
                busy == 1
                ? @"One browser, container or download is still running, and closing "
                   "the window stops it."
                : [NSString stringWithFormat:
                   @"%ld browsers, containers or downloads are still running, and "
                    "closing the window stops them.", busy];
            [panel addButtonWithTitle:@"Close"];
            [panel addButtonWithTitle:@"Keep open"];
            if ([panel runModal] != NSAlertFirstButtonReturn)
                return;
        }
        [NSApp terminate:nil];
    }];
    return NO;
}

- (void)windowWillClose:(NSNotification *)notification
{
    /* A strong local first: this array is the only thing holding the window,
     * and it is still closing. */
    NSWindow *window = notification.object;
    [self.windows removeObject:window];
    note([NSString stringWithFormat:@"Window closed (%lu left).",
          (unsigned long)self.windows.count]);
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)app
{
    return YES;
}

/* The whole reason this app exists. Pressing the Dock icon, or picking the app
 * out of Stage Manager or Cmd-Tab, brings the window back - rather than waking
 * a copy of Chrome that answers by opening a New Tab. */
- (BOOL)applicationShouldHandleReopen:(NSApplication *)app hasVisibleWindows:(BOOL)visible
{
    if (!visible) {
        if (self.windows.count == 0)
            [self openWindow:nil];
        else
            [self.windows.lastObject makeKeyAndOrderFront:nil];
        [NSApp activateIgnoringOtherApps:YES];
    }
    return YES;
}

/* Ask the manager to stop, and go. Not "terminate later": holding the app open
 * until the server has finished meant answering NSTerminateLater and waiting for
 * a reply that could only be sent from the main queue - which, if the terminate
 * came from a main-queue block, could never run. The app would then sit on
 * "Closing the manager" for ever with nothing able to move it.
 *
 * The server does not need us there for the last part anyway: SIGTERM is its cue
 * to close the browsers it launched and stop the containers it started, and
 * --owner-pid means that even a SIGTERM that never lands ends the same way a
 * second later. */
- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication *)app
{
    if (self.closing || self.adopted || self.server == 0)
        return NSTerminateNow;

    self.closing = YES;
    note(@"Window closed; asking the manager to stop.");
    kill(-self.server, SIGTERM);
    return NSTerminateNow;
}

@end


/* The other half of the spawn above: this process is already the app as far as
 * TCC is concerned, so handing over to gui.sh from here gives the manager the
 * app's own access to the folder it lives in. Nothing of AppKit is touched on
 * this path - it is the old launcher, kept for the one thing it was good at. */
static int serve(int argc, char **argv)
{
    char project[PATH_MAX];
    if (project_dir(project, sizeof(project)) != 0 || chdir(project) != 0) {
        fprintf(stderr, "  Could not reach the folder EngineShelf.app is in.\n");
        return 1;
    }

    char *forward[16] = {(char *)"bash", (char *)"gui.sh", (char *)"--no-open"};
    int count = 3;
    for (int i = 2; i < argc && count < 14; i++)
        forward[count++] = argv[i];
    forward[count] = NULL;

    execv("/bin/bash", forward);
    fprintf(stderr, "  Could not start gui.sh.\n");
    return 127;
}

int main(int argc, char **argv)
{
    if (argc > 1 && strcmp(argv[1], "--serve") == 0)
        return serve(argc, argv);

    @autoreleasepool {
        [NSApplication sharedApplication];

        char project[PATH_MAX];
        if (project_dir(project, sizeof(project)) != 0) {
            alert(@"Could not work out where the app lives.");
            return 1;
        }
        if (chdir(project) != 0) {
            /* The usual cause is macOS withholding access to the enclosing folder. */
            alert(@"macOS is blocking access to the folder this app is in.\n\n"
                   "Open System Settings > Privacy & Security > Files and Folders "
                   "and allow EngineShelf, then open it again.\n\n"
                   "Or run ./gui.sh from Terminal instead.");
            return 1;
        }
        if (access("gui.sh", X_OK) != 0) {
            alert(@"gui.sh is missing.\n\n"
                   "Keep EngineShelf.app inside the engineshelf folder, "
                   "or use the packaged release.");
            return 1;
        }

        [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
        /* Static, not a local: see the note above the class. */
        static Manager *manager = nil;
        manager = [[Manager alloc]
            initWithProject:[NSString stringWithUTF8String:project]];
        NSApp.delegate = manager;
        [NSApp run];
    }
    return 0;
}
