// Injected into the *demo copy* of Edict MDM (DYLD_INSERT_LIBRARIES) for README screenshots.
// 1. Seeds placeholder keychain items from inside the demo process so the app can read
//    them without a keychain prompt. Refuses to run unless the bundle id ends in ".demo".
// 2. On SIGUSR1, writes a PNG of each visible window to $EDICT_DEMO_SHOTS (an app may
//    capture its own windows without Screen Recording permission).
#import <AppKit/AppKit.h>
#import <Security/Security.h>
#import <dlfcn.h>

static void seed(NSString *service, NSString *account) {
    NSDictionary *q = @{(id)kSecClass: (id)kSecClassGenericPassword, (id)kSecAttrService: service, (id)kSecAttrAccount: account};
    NSData *v = [@"demo" dataUsingEncoding:NSUTF8StringEncoding];
    if (SecItemUpdate((CFDictionaryRef)q, (CFDictionaryRef)@{(id)kSecValueData: v}) == errSecSuccess) return;
    NSMutableDictionary *add = [q mutableCopy];
    add[(id)kSecValueData] = v;
    OSStatus st = SecItemAdd((CFDictionaryRef)add, NULL);
    NSLog(@"[demo] seed %@ -> %d", account, (int)st);
}

typedef CGImageRef (*WinImgFn)(CGRect, uint32_t, uint32_t, uint32_t);
typedef CGImageRef (*WinArrFn)(CGRect, CFArrayRef, uint32_t);

static void shoot(void) {
    NSString *dir = NSProcessInfo.processInfo.environment[@"EDICT_DEMO_SHOTS"];
    if (!dir) return;
    WinImgFn fn = (WinImgFn)dlsym(RTLD_DEFAULT, "CGWindowListCreateImage");
    static int n = 0;
    // Composite of every visible window (main window + any sheet on top), front to back.
    WinArrFn afn = (WinArrFn)dlsym(RTLD_DEFAULT, "CGWindowListCreateImageFromArray");
    NSMutableArray *ids = [NSMutableArray array];
    for (NSWindow *w in NSApp.orderedWindows) if (w.isVisible && w.frame.size.width >= 200) [ids addObject:@(w.windowNumber)];
    if (afn && ids.count > 1) {
        CFMutableArrayRef arr = CFArrayCreateMutable(NULL, 0, NULL);
        for (NSNumber *i in ids) CFArrayAppendValue(arr, (const void *)(uintptr_t)i.unsignedIntValue);
        CGImageRef img = afn(CGRectNull, arr, 1);
        CFRelease(arr);
        if (img) {
            NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithCGImage:img];
            CGImageRelease(img);
            [[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}]
                writeToFile:[dir stringByAppendingPathComponent:[NSString stringWithFormat:@"composite-%02d.png", ++n]] atomically:YES];
        }
    }
    for (NSWindow *w in NSApp.windows) {
        if (!w.isVisible || w.frame.size.width < 200) continue;
        CGImageRef img = fn ? fn(CGRectNull, 8 /*IncludingWindow*/, (uint32_t)w.windowNumber, 1 /*BoundsIgnoreFraming*/) : NULL;
        NSBitmapImageRep *rep = img ? [[NSBitmapImageRep alloc] initWithCGImage:img] : nil;
        if (img) CGImageRelease(img);
        if (!rep) {  // fallback: let AppKit draw the view tree
            NSView *v = w.contentView.superview ?: w.contentView;
            rep = [v bitmapImageRepForCachingDisplayInRect:v.bounds];
            [v cacheDisplayInRect:v.bounds toBitmapImageRep:rep];
        }
        NSString *path = [dir stringByAppendingPathComponent:[NSString stringWithFormat:@"win-%02d-%ld.png", ++n, (long)w.windowNumber]];
        [[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:path atomically:YES];
        NSLog(@"[demo] shot %@ (%@) %@", path, fn ? @"CGWindowList" : @"cacheDisplay", w.title);
    }
}

static NSTableView *findTable(NSView *v) {
    if ([v isKindOfClass:NSTableView.class] && ((NSTableView *)v).tableColumns.count > 8) return (NSTableView *)v;
    for (NSView *k in v.subviews) { NSTableView *t = findTable(k); if (t) return t; }
    return nil;
}

// SIGUSR2: apply column commands from $EDICT_DEMO_CMD, one per line:
//   hide|<title>   show|<title>   move|<title>|<index>   width|<title>|<points>
static void columns(void) {
    NSString *cmdPath = NSProcessInfo.processInfo.environment[@"EDICT_DEMO_CMD"];
    NSString *cmds = cmdPath ? [NSString stringWithContentsOfFile:cmdPath encoding:NSUTF8StringEncoding error:nil] : nil;
    for (NSWindow *w in NSApp.windows) {
        NSTableView *t = findTable(w.contentView);
        if (!t) continue;
        for (NSTableColumn *c in t.tableColumns) NSLog(@"[demo] column '%@' hidden=%d w=%.0f", c.title, c.isHidden, c.width);
        for (NSString *line in [cmds componentsSeparatedByString:@"\n"]) {
            NSArray *p = [line componentsSeparatedByString:@"|"];
            if (p.count < 2) continue;
            NSTableColumn *col = nil;
            for (NSTableColumn *c in t.tableColumns) if ([c.title isEqualToString:p[1]]) col = c;
            if (!col) { NSLog(@"[demo] no column %@", p[1]); continue; }
            if ([p[0] isEqualToString:@"hide"]) col.hidden = YES;
            if ([p[0] isEqualToString:@"show"]) col.hidden = NO;
            if ([p[0] isEqualToString:@"width"] && p.count > 2) col.width = [p[2] doubleValue];
            if ([p[0] isEqualToString:@"move"] && p.count > 2)
                [t moveColumn:[t.tableColumns indexOfObject:col] toColumn:[p[2] integerValue]];
        }
    }
}

__attribute__((constructor)) static void demo_init(void) {
    NSString *bid = NSBundle.mainBundle.bundleIdentifier;
    if (![bid hasSuffix:@".demo"]) { NSLog(@"[demo] refusing: bundle id %@", bid); return; }
    NSString *api = NSProcessInfo.processInfo.environment[@"EDICT_DEMO_API"];
    if (api) seed(bid, [api stringByAppendingString:@"|admin"]);
    for (NSString *a in @[@"EdictMDM.nanoMDMAPIKey", @"EdictMDM.kmfddmAPIKey", @"EdictMDM.scepChallenge",
                          @"BlueConnectAdmin.munkiReportAPIToken"]) seed(bid, a);
    signal(SIGUSR1, SIG_IGN);
    static dispatch_source_t src;
    src = dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL, SIGUSR1, 0, dispatch_get_main_queue());
    dispatch_source_set_event_handler(src, ^{ shoot(); });
    dispatch_resume(src);
    signal(SIGUSR2, SIG_IGN);
    static dispatch_source_t src2;
    src2 = dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL, SIGUSR2, 0, dispatch_get_main_queue());
    dispatch_source_set_event_handler(src2, ^{ columns(); });
    dispatch_resume(src2);
}
