// CodexPrefsController.m
//
// PreferenceLoader compiled bundle for the Codex CLI iOS port.
// Hosts the Settings.app pane specifiers (loaded from CodexPrefs.plist
// inside the bundle) and implements the action methods wired to PSButtonCell
// rows via the "action" key in the specifier plist.
//
// The pane specifiers (model / sandbox / approval / toggles / log level /
// API key) are defined in Resources/CodexPrefs.plist so they can be edited
// without touching code. Only the buttons that need to DO something are
// implemented here as Objective-C methods.
//
// Author: tg@xauszulay

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <Preferences/Preferences.h>

#include <spawn.h>
#include <sys/wait.h>
#include <unistd.h>
#include <string.h>
#include <errno.h>

extern char **environ;

// Preference domain written by the Settings pane specifiers
// (defaults = com.openai.codex-ios in the plist).
static NSString *const kPrefDomain = @"com.openai.codex-ios";

// specifiersFromPlistPath: was the classic PSListController selector used
// on iOS 3–12, but it was removed from Preferences.framework on newer iOS.
// On iOS 13+ (including 16.1.1 where this bundle ships) PSListController
// exposes -loadSpecifiersFromPlistName:target:, which takes the plist name
// without extension and resolves it inside the controller's own bundle.
// Forward-declare it so the call type-checks without pulling in Cephei.
@interface PSListController (CodexPrivate)
- (NSMutableArray *)loadSpecifiersFromPlistName:(NSString *)name target:(id)target;
@end

@interface CodexPrefsController : PSListController
@end

@implementation CodexPrefsController

// PSListController loads its specifiers from a plist resource bundled inside
// the .bundle. The file lives at CodexPrefs.bundle/CodexPrefs.plist.
- (NSArray *)specifiers {
    if (_specifiers == nil) {
        _specifiers = [[NSMutableArray alloc] initWithArray:[self loadSpecifiersFromPlistName:@"CodexPrefs" target:self]];
    }
    return _specifiers;
}

#pragma mark - Paths

// The deb installs everything under the jailbreak root /var/jb. The codex
// config dir lives at /var/jb/var/mobile/.codex (HOME=/var/jb/var/mobile for
// the mobile user). Logs are written there by the Rust engine when RUST_LOG
// is raised above the default.
+ (NSString *)codexConfigDir {
    return @"/var/jb/var/mobile/.codex";
}

+ (NSString *)codexLibDir {
    return @"/var/jb/usr/local/lib/codex";
}

+ (NSUserDefaults *)prefs {
    return [[NSUserDefaults alloc] initWithSuiteName:kPrefDomain];
}

#pragma mark - UI helpers

- (void)showAlert:(NSString *)title message:(NSString *)message {
    if (message.length > 4000) {
        message = [[message substringToIndex:4000] stringByAppendingString:@"\n…(truncated)"];
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        UIAlertController *a = [UIAlertController alertControllerWithTitle:title
                                                                    message:message
                                                             preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:NSLocalizedString(@"OK", @"")
                                               style:UIAlertActionStyleDefault
                                             handler:nil]];
        [self presentViewController:a animated:YES completion:nil];
    });
}

// Best-effort: open a path in Filza (the de-facto file manager on jailbroken
// iOS) via its URL scheme. If Filza is not installed, fall back to an alert
// that lists the directory contents so the user can still see what is inside
// and copy the path into NewTerm / Filza manually.
- (void)openPath:(NSString *)path title:(NSString *)title {
    NSFileManager *fm = NSFileManager.defaultManager;
    if (![fm fileExistsAtPath:path]) {
        [self showAlert:title
                message:[NSString stringWithFormat:@"%@\n\n%@", path, NSLocalizedString(@"does not exist.", @"")]];
        return;
    }

    // Try Filza first. filza://<absolute-path> opens that path in Filza.
    // We do NOT gate on canOpenURL: because Settings.app does not declare
    // the filza scheme in LSApplicationQueriesSchemes, so canOpenURL would
    // return NO even when Filza is installed. Just attempt openURL:.
    NSURL *filzaURL = [NSURL URLWithString:[NSString stringWithFormat:@"filza://%@", path]];
    if (filzaURL) {
        [UIApplication.sharedApplication openURL:filzaURL
                                         options:@{}
                               completionHandler:^(BOOL success) {
            if (success) {
                return;
            }
            [self showFolderListing:path title:title];
        }];
        return;
    }
    [self showFolderListing:path title:title];
}

// Fallback UI: list the directory's contents in an alert.
- (void)showFolderListing:(NSString *)path title:(NSString *)title {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSDirectoryEnumerator *e = [fm enumeratorAtPath:path];
    NSMutableArray *lines = [NSMutableArray array];
    [lines addObject:path];
    [lines addObject:@""];
    NSInteger count = 0;
    NSString *name;
    while ((name = [e nextObject])) {
        if (++count > 40) {
            [lines addObject:@"…"];
            break;
        }
        NSDictionary *attrs = [e fileAttributes];
        unsigned long long size = [attrs fileSize];
        NSString *type = attrs.fileType;
        NSString *tag = ([type isEqualToString:NSFileTypeDirectory]) ? @"/" : @"";
        [lines addObject:[NSString stringWithFormat:@"%@%@  (%llu B)", name, tag, size]];
    }
    if (count == 0) {
        [lines addObject:NSLocalizedString(@"(empty)", @"")];
    }
    [lines addObject:@""];
    [lines addObject:NSLocalizedString(@"Install Filza to browse this folder graphically.", @"")];
    [self showAlert:title message:[lines componentsJoinedByString:@"\n"]];
}

// Open an https URL in Safari / the default browser.
- (void)openURL:(NSString *)urlString {
    NSURL *url = [NSURL URLWithString:urlString];
    if (!url) {
        return;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        [UIApplication.sharedApplication openURL:url options:@{} completionHandler:nil];
    });
}

// Run a short shell command via the Procursus shell and return its stdout+stderr.
// NSTask is macOS-only and not in the iOS SDK, so we use posix_spawn directly
// with /var/jb/bin/sh -c "<cmd>", capturing output through a pipe.
- (NSString *)shell:(NSString *)cmd {
    int pipefd[2];
    if (pipe(pipefd) != 0) {
        return [NSString stringWithFormat:@"%@: pipe: %s",
                    NSLocalizedString(@"shell failed", @""), strerror(errno)];
    }

    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);
    posix_spawn_file_actions_adddup2(&actions, pipefd[1], STDOUT_FILENO);
    posix_spawn_file_actions_adddup2(&actions, pipefd[1], STDERR_FILENO);
    posix_spawn_file_actions_addclose(&actions, pipefd[0]);
    posix_spawn_file_actions_addclose(&actions, pipefd[1]);

    const char *argv[] = {"/var/jb/bin/sh", "-c", [cmd UTF8String], NULL};
    pid_t pid = 0;
    int rc = posix_spawnp(&pid, "/var/jb/bin/sh", &actions, NULL,
                          (char *const *)argv, environ);
    posix_spawn_file_actions_destroy(&actions);
    close(pipefd[1]);

    if (rc != 0) {
        close(pipefd[0]);
        return [NSString stringWithFormat:@"%@: posix_spawn: %s",
                    NSLocalizedString(@"shell failed", @""), strerror(rc)];
    }

    NSMutableData *data = [NSMutableData data];
    char buf[4096];
    ssize_t n;
    while ((n = read(pipefd[0], buf, sizeof(buf))) > 0) {
        [data appendBytes:buf length:(NSUInteger)n];
    }
    close(pipefd[0]);

    int status = 0;
    waitpid(pid, &status, 0);

    NSString *out = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    return out ?: @"";
}

#pragma mark - Button actions

// "Open Config Folder" — reveal ~/.codex in Filza, or list it inline.
- (void)openConfigFolder {
    [self openPath:[[self class] codexConfigDir] title:NSLocalizedString(@"Codex Config Folder", @"")];
}

// "Open Logs" — reveal ~/.codex/log if present, otherwise ~/.codex.
- (void)openLogs {
    NSString *cfg = [[self class] codexConfigDir];
    NSString *logDir = [cfg stringByAppendingPathComponent:@"log"];
    if ([NSFileManager.defaultManager fileExistsAtPath:logDir]) {
        [self openPath:logDir title:NSLocalizedString(@"Codex Logs", @"")];
    } else {
        [self openPath:cfg title:NSLocalizedString(@"Codex Logs", @"")];
    }
}

// "Reset Authentication" — confirm, then remove credentials + auth.json +
// auth.toml + the Settings API key. Does NOT touch config.toml / sessions.
- (void)resetAuthentication {
    UIAlertController *confirm =
        [UIAlertController alertControllerWithTitle:NSLocalizedString(@"Reset Authentication", @"")
                                            message:NSLocalizedString(@"Remove the saved API key / ChatGPT login? This cannot be undone.", @"")
                                     preferredStyle:UIAlertControllerStyleAlert];
    [confirm addAction:[UIAlertAction actionWithTitle:NSLocalizedString(@"Cancel", @"")
                                                 style:UIAlertActionStyleCancel
                                               handler:nil]];
    __weak typeof(self) weakSelf = self;
    [confirm addAction:[UIAlertAction actionWithTitle:NSLocalizedString(@"Reset", @"")
                                                 style:UIAlertActionStyleDestructive
                                               handler:^(UIAlertAction *_) {
        [weakSelf doResetAuthentication];
    }]];
    [self presentViewController:confirm animated:YES completion:nil];
}

- (void)doResetAuthentication {
    NSString *cfg = [[self class] codexConfigDir];
    NSFileManager *fm = NSFileManager.defaultManager;
    NSMutableArray *removed = [NSMutableArray array];
    for (NSString *name in @[@"credentials", @"auth.json", @"auth.toml"]) {
        NSString *p = [cfg stringByAppendingPathComponent:name];
        if ([fm fileExistsAtPath:p]) {
            NSError *err = nil;
            [fm removeItemAtPath:p error:&err];
            [removed addObject:err ? [NSString stringWithFormat:@"%@ (%@)", name, err.localizedDescription] : name];
        }
    }
    // Clear the API key stored in the Settings preference domain.
    NSUserDefaults *prefs = [[self class] prefs];
    [prefs removeObjectForKey:@"apiKey"];
    [prefs synchronize];

    NSString *msg;
    if (removed.count == 0) {
        msg = NSLocalizedString(@"No saved credentials were found. The Settings API key was cleared.", @"");
    } else {
        msg = [NSString stringWithFormat:@"%@:\n%@\n\n%@",
                   NSLocalizedString(@"Removed", @""), [removed componentsJoinedByString:@"\n"],
                   NSLocalizedString(@"Run 'codex-auth' in NewTerm to sign in again.", @"")];
    }
    [self showAlert:NSLocalizedString(@"Authentication Reset", @"") message:msg];
}

// "Run Diagnostics" — print version, binary presence, config dir listing,
// auth status, and the current Settings preferences. Output goes to an alert
// so the user can read it / screenshot it for a bug report.
- (void)runDiagnostics {
    NSMutableString *out = [NSMutableString string];
    NSString *cfg = [[self class] codexConfigDir];
    NSString *codexLib = [[self class] codexLibDir];
    NSString *bin = [codexLib stringByAppendingPathComponent:@"codex-ios"];
    NSString *wrap = @"/var/jb/usr/local/bin/codex";
    NSFileManager *fm = NSFileManager.defaultManager;
    NSUserDefaults *prefs = [[self class] prefs];

    [out appendFormat:@"== Codex CLI iOS diagnostics ==\n\n"];

    [out appendFormat:@"wrapper: %@  %@\n", wrap,
        [fm fileExistsAtPath:wrap] ? @"present" : @"MISSING"];
    [out appendFormat:@"engine:  %@  %@\n", bin,
        [fm fileExistsAtPath:bin] ? @"present" : @"MISSING"];

    if ([fm fileExistsAtPath:bin]) {
        NSString *v = [self shell:[NSString stringWithFormat:@"'%@' --version 2>&1", bin]];
        v = [v stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        [out appendFormat:@"--version: %@\n", v.length ? v : @"(empty)"];
    }

    [out appendFormat:@"\nconfig dir: %@\n", cfg];
    if ([fm fileExistsAtPath:cfg]) {
        NSArray *items = [fm contentsOfDirectoryAtPath:cfg error:nil];
        [out appendFormat:@"  %@ item(s): %@\n", @(items.count),
            items.count ? [items componentsJoinedByString:@", "] : @"(empty)"];
    } else {
        [out appendFormat:@"  (does not exist — run 'codex' once to create it)\n"];
    }

    BOOL hasCreds = [fm fileExistsAtPath:[cfg stringByAppendingPathComponent:@"credentials"]];
    BOOL hasAuth  = [fm fileExistsAtPath:[cfg stringByAppendingPathComponent:@"auth.json"]];
    NSString *apiKey = [prefs stringForKey:@"apiKey"];
    [out appendFormat:@"\nauth: credentials=%@ auth.json=%@ settingsApiKey=%@\n",
        hasCreds ? @"yes" : @"no",
        hasAuth  ? @"yes" : @"no",
        apiKey.length ? @"yes" : @"no"];

    [out appendFormat:@"\nsettings (%@):\n", kPrefDomain];
    for (NSString *key in @[@"model", @"sandbox", @"approval", @"webSearch",
                            @"noAltScreen", @"fastMode", @"memories", @"logLevel"]) {
        id v = [prefs objectForKey:key];
        [out appendFormat:@"  %@ = %@\n", key, v ?: @"(default)"];
    }

    [self showAlert:NSLocalizedString(@"Codex Diagnostics", @"") message:out];
}

// "Open open.ai" — the official OpenAI website, kept as an attribution link
// to the upstream project this is a port of.
- (void)openOpenAISite {
    [self openURL:@"https://open.ai"];
}

// "Open upstream repo" — github.com/openai/codex.
- (void)openUpstreamRepo {
    [self openURL:@"https://github.com/openai/codex"];
}

// "Respring" — restart SpringBoard so the Settings pane / bundle reloads.
// This is the classic `killall -9 SpringBoard` via the Procursus shell.
- (void)respring {
    [self shell:@"killall -9 SpringBoard 2>&1 || true"];
}

@end
