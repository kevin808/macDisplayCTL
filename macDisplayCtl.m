#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <IOKit/IOKitLib.h>
#import <IOKit/pwr_mgt/IOPM.h>
#include <dlfcn.h>
#include <sys/sysctl.h>
#include <sys/file.h>
#include <fcntl.h>
#include <signal.h>
#include <unistd.h>
#include <math.h>

// Private WindowServer APIs; availability depends on macOS and hardware.
typedef CGError (*DisplayListFn)(uint32_t, CGDirectDisplayID *, uint32_t *);
typedef CGError (*DisplayEnabledFn)(CGDisplayConfigRef, CGDirectDisplayID, bool);
typedef CFDictionaryRef (*DisplayInfoFn)(CGDirectDisplayID);
typedef CFUUIDRef (*DisplayUUIDFn)(CGDirectDisplayID);
static DisplayListFn getDisplayList;
static DisplayEnabledFn configureEnabled;
static DisplayInfoFn copyDisplayInfo;
static DisplayUUIDFn createDisplayUUID;

// Explicit override is also propagated by the app to its child processes.
static BOOL usesChinese(void) {
    static BOOL chinese;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *language = NSProcessInfo.processInfo.environment[@"MACDISPLAYCTL_LANGUAGE"]
            ?: NSLocale.preferredLanguages.firstObject ?: @"en";
        chinese = [language.lowercaseString hasPrefix:@"zh"];
    });
    return chinese;
}

static NSString *localize(NSString *chinese, NSString *english) {
    return usesChinese() ? chinese : english;
}

static void fail(NSString *message) {
    fprintf(stderr, localize(@"错误：%s\n", @"Error: %s\n").UTF8String, message.UTF8String);
}

static void usage(void) {
    puts(localize(@"显示器启停工具（macOS）\n用法：macDisplayCtl list [--json]\n      macDisplayCtl on|off|toggle builtin|external|all|ID [--dry-run]\n      macDisplayCtl project internal|duplicate|extend|external [外屏ID] [--dry-run]\n      macDisplayCtl guard start|stop|status\n      macDisplayCtl watch --dry-run --once\n      macDisplayCtl language\n\n默认拒绝停用最后一块可用的非虚拟屏。\n--allow-all-off 可显式允许全部停用；--dry-run 只显示操作计划。\n这是系统显示布局启停，不是 DDC 硬件电源开关。", @"macDisplayCtl display control (macOS)\nUsage: macDisplayCtl list [--json]\n       macDisplayCtl on|off|toggle builtin|external|all|ID [--dry-run]\n       macDisplayCtl project internal|duplicate|extend|external [external-ID] [--dry-run]\n       macDisplayCtl guard start|stop|status\n       macDisplayCtl watch --dry-run --once\n       macDisplayCtl language\n\nDisabling the last usable non-virtual display is refused by default.\n--allow-all-off explicitly permits disabling all displays; --dry-run previews changes.\nThis changes the macOS display layout, not DDC hardware power.").UTF8String);
}

static NSString *bootID(void) {
    char buffer[128] = {0};
    size_t length = sizeof(buffer);
    if (sysctlbyname("kern.bootsessionuuid", buffer, &length, NULL, 0) != 0)
        return nil;
    return [NSString stringWithUTF8String:buffer];
}

static NSString *cachePath(void) {
    return [NSHomeDirectory() stringByAppendingPathComponent:
            @"Library/Application Support/macDisplayCtl/displays.json"];
}

static NSString *displayUUID(CGDirectDisplayID display) {
    if (!createDisplayUUID) return nil;
    CFUUIDRef uuid = createDisplayUUID(display);
    if (!uuid) return nil;
    CFStringRef value = CFUUIDCreateString(kCFAllocatorDefault, uuid);
    CFRelease(uuid);
    return CFBridgingRelease(value);
}

static NSString *displayName(NSDictionary *info, BOOL builtin, uint32_t display) {
    if (builtin) return localize(@"内置显示器", @"Built-in display");
    id name = info[@"DisplayProductName"];
    if ([name isKindOfClass:NSString.class] && [name length]) return name;
    if ([name isKindOfClass:NSDictionary.class]) {
        for (NSString *locale in (usesChinese() ? @[@"zh_CN", @"zh_TW", @"en_US", @"en"] : @[@"en_US", @"en", @"zh_CN", @"zh_TW"])) {
            if ([name[locale] isKindOfClass:NSString.class] && [name[locale] length]) return name[locale];
        }
        for (id value in [name allValues])
            if ([value isKindOfClass:NSString.class] && [value length]) return value;
    }
    return builtin ? localize(@"内置显示器", @"Built-in display") : [NSString stringWithFormat:localize(@"外置显示器 %u", @"External display %u"), display];
}

static NSArray<NSDictionary *> *loadRemembered(void) {
    NSString *boot = bootID();
    if (!boot) return @[]; // IDs from another boot must never select a target.
    NSData *data = [NSData dataWithContentsOfFile:cachePath()];
    if (!data) return @[];
    id object = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![object isKindOfClass:NSDictionary.class] || ![object[@"boot"] isEqual:boot])
        return @[];
    id rows = object[@"displays"];
    if (![rows isKindOfClass:NSArray.class]) return @[];
    NSMutableArray *valid = [NSMutableArray array];
    for (id row in rows) {
        if (![row isKindOfClass:NSDictionary.class] ||
            ![row[@"id"] isKindOfClass:NSNumber.class] ||
            [row[@"id"] unsignedLongLongValue] == 0 ||
            [row[@"id"] unsignedLongLongValue] > UINT32_MAX ||
            ![row[@"name"] isKindOfClass:NSString.class] ||
            ![row[@"builtin"] isKindOfClass:NSNumber.class]) continue;
        NSString *current = displayUUID([row[@"id"] unsignedIntValue]);
        id previous = row[@"uuid"];
        if (current && [previous isKindOfClass:NSString.class] &&
            ![current isEqual:previous]) continue;
        [valid addObject:row];
    }
    return valid;
}

static NSString *monitorIdentity(uint32_t vendor, uint32_t product, uint32_t serial) {
    return vendor && product ? [NSString stringWithFormat:@"%u:%u:%u", vendor, product, serial] : nil;
}

static NSString *edidIdentity(id data) {
    if (![data isKindOfClass:NSData.class] || [data length] < 128) return nil;
    const uint8_t *bytes = [data bytes];
    const uint8_t header[] = {0, 255, 255, 255, 255, 255, 255, 0};
    if (memcmp(bytes, header, sizeof(header))) return nil;
    return monitorIdentity((bytes[8] << 8) | bytes[9], bytes[10] | (bytes[11] << 8),
                           (uint32_t)bytes[12] | ((uint32_t)bytes[13] << 8) |
                           ((uint32_t)bytes[14] << 16) | ((uint32_t)bytes[15] << 24));
}

static NSString *portMonitorIdentity(NSDictionary *values) {
    // A port can retain its EDID after hot-plug detect goes low.
    if ([values[@"HPD_StateDescription"] isEqual:@"Low"]) return nil;
    return edidIdentity(values[@"EDID"] ?: values[@"IODisplayEDID"]);
}

// Physical port EDIDs remain available when a connected display is soft-disabled.
// CoreGraphics "online" alone cannot distinguish that state from an unplugged ID.
static NSSet *connectedMonitors(void) {
    NSMutableSet *identities = [NSMutableSet set];
    for (NSString *className in @[@"IOPortTransportStateDisplayPort", @"IODisplayConnect"]) {
        io_iterator_t iterator = 0;
        if (IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(className.UTF8String), &iterator) != KERN_SUCCESS)
            return nil; // A failed probe is unknown, not evidence of disconnection.
        io_service_t service;
        while ((service = IOIteratorNext(iterator))) {
            CFMutableDictionaryRef properties = NULL;
            if (IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0) != KERN_SUCCESS) {
                IOObjectRelease(service); IOObjectRelease(iterator); return nil;
            }
            NSDictionary *values = CFBridgingRelease(properties);
            NSString *identity = portMonitorIdentity(values);
            if (identity) [identities addObject:identity];
            IOObjectRelease(service);
        }
        IOObjectRelease(iterator);
    }
    return identities;
}

static id connectionState(NSDictionary *row, NSSet *monitors) {
    if ([row[@"builtin"] boolValue] || [row[@"online"] boolValue]) return @YES;
    if (!monitors) return NSNull.null;
    NSString *identity = monitorIdentity([row[@"vendor"] unsignedIntValue], [row[@"product"] unsignedIntValue],
                                         [row[@"serial"] unsignedIntValue]);
    if (identity) return @([monitors containsObject:identity]);
    // Older caches lack EDID identity; only an empty physical inventory is conclusive.
    return monitors.count ? NSNull.null : @NO;
}

static NSArray<NSDictionary *> *discover(NSString **error) {
    CGDirectDisplayID ids[256];
    uint32_t count = 0;
    CGError result = getDisplayList(256, ids, &count);
    if (result != kCGErrorSuccess || count >= 256) {
        *error = [NSString stringWithFormat:localize(@"无法取得完整显示器列表（CGError=%d）。", @"Unable to retrieve the complete display list (CGError=%d)."), result];
        return nil;
    }
    NSMutableDictionary<NSNumber *, NSDictionary *> *byID = [NSMutableDictionary dictionary];
    for (uint32_t i = 0; i < count; i++) {
        CGDirectDisplayID display = ids[i];
        if (!display) continue;
        BOOL builtin = CGDisplayIsBuiltin(display) != 0;
        BOOL online = CGDisplayIsOnline(display) != 0;
        BOOL mirror = CGDisplayIsInMirrorSet(display) || CGDisplayIsInHWMirrorSet(display);
        BOOL active = CGDisplayIsActive(display) != 0;
        NSString *uuid = displayUUID(display);
        // SkyLight can include reserved IDs with neither a display nor an identity.
        // Own soft-disabled targets can still be restored through the boot cache.
        if (!online && !builtin && !uuid) continue;
        NSDictionary *info = copyDisplayInfo ? CFBridgingRelease(copyDisplayInfo(display)) : nil;
        if (![info isKindOfClass:NSDictionary.class]) info = @{};
        id virtual = info[@"kCGDisplayIsVirtualDevice"] ?: info[@"DisplayIsVirtual"];
        NSMutableDictionary *row = [@{
            @"id": @(display), @"builtin": @(builtin),
            @"name": displayName(info, builtin, display),
            @"online": @(online), @"active": @(active), @"mirror": @(mirror),
            @"enabled": @(online && (active || mirror)),
            @"mirrorOf": @(CGDisplayMirrorsDisplay(display)),
            @"vendor": @(CGDisplayVendorNumber(display)), @"product": @(CGDisplayModelNumber(display)),
            @"serial": @(CGDisplaySerialNumber(display)),
            @"width": @(CGDisplayPixelsWide(display)), @"height": @(CGDisplayPixelsHigh(display)),
            @"x": @(CGDisplayBounds(display).origin.x), @"y": @(CGDisplayBounds(display).origin.y),
            @"virtual": @([virtual respondsToSelector:@selector(boolValue)] && [virtual boolValue]),
            @"exclusive": @([info[@"DisplayIsSLVDExclusive"] boolValue]),
            @"remembered": @NO, @"main": @(CGDisplayIsMain(display) != 0)
        } mutableCopy];
        if (uuid) row[@"uuid"] = uuid;
        byID[@(display)] = row;
    }
    for (NSDictionary *old in loadRemembered()) {
        NSNumber *identifier = old[@"id"];
        if (byID[identifier]) {
            // Soft-disabled built-in panels can lose live classification/name.
            NSMutableDictionary *row = [byID[identifier] mutableCopy];
            if (![row[@"enabled"] boolValue]) {
                row[@"builtin"] = old[@"builtin"];
                row[@"name"] = [old[@"builtin"] boolValue] ? localize(@"内置显示器", @"Built-in display") : old[@"name"];
                row[@"virtual"] = old[@"virtual"] ?: @NO;
                if (!row[@"uuid"] && old[@"uuid"]) row[@"uuid"] = old[@"uuid"];
                for (NSString *key in @[@"vendor", @"product", @"serial"])
                    if (![row[key] unsignedIntValue] && old[key]) row[key] = old[key];
            }
            byID[identifier] = row;
        } else {
            NSMutableDictionary *row = [old mutableCopy];
            row[@"enabled"] = @NO;
            row[@"online"] = @NO;
            row[@"active"] = @NO;
            row[@"mirror"] = @NO;
            row[@"main"] = @NO;
            row[@"exclusive"] = @NO;
            row[@"remembered"] = @YES;
            if ([row[@"builtin"] boolValue]) row[@"name"] = localize(@"内置显示器", @"Built-in display");
            byID[identifier] = row;
        }
    }
    NSSet *monitors = connectedMonitors();
    for (NSNumber *identifier in byID.allKeys) {
        NSMutableDictionary *row = [byID[identifier] mutableCopy];
        row[@"connected"] = connectionState(row, monitors);
        byID[identifier] = row;
    }
    return [[byID allValues] sortedArrayUsingComparator:^NSComparisonResult(id a, id b) {
        return [a[@"id"] compare:b[@"id"]];
    }];
}

static BOOL saveRemembered(NSArray *rows, NSString **error) {
    NSString *boot = bootID();
    if (!boot) {
        *error = localize(@"无法记录本次启动的显示器身份，操作已取消。", @"Unable to save display identities for this boot. Operation cancelled.");
        return NO;
    }
    NSError *failure = nil;
    NSString *directory = [cachePath() stringByDeletingLastPathComponent];
    if (![[NSFileManager defaultManager] createDirectoryAtPath:directory
                                 withIntermediateDirectories:YES
                                 attributes:nil error:&failure]) {
        *error = failure.localizedDescription;
        return NO;
    }
    NSData *data = [NSJSONSerialization dataWithJSONObject:@{@"boot": boot, @"displays": rows}
                                                 options:NSJSONWritingPrettyPrinted error:&failure];
    if (!data || ![data writeToFile:cachePath() options:NSDataWritingAtomic error:&failure]) {
        *error = failure.localizedDescription;
        return NO;
    }
    return YES;
}

static void printRows(NSArray *rows) {
    for (NSDictionary *row in rows) {
        printf("%-10u %-8s %-8s %s%s%s\n",
               [row[@"id"] unsignedIntValue],
               [row[@"builtin"] boolValue] ? localize(@"内置", @"Built-in").UTF8String : localize(@"外置", @"External").UTF8String,
               [row[@"enabled"] boolValue] ? localize(@"启用", @"Enable").UTF8String : localize(@"停用", @"Disable").UTF8String,
               [row[@"name"] UTF8String],
               [row[@"main"] boolValue] ? localize(@" [主屏]", @" [Main]").UTF8String : "",
               [row[@"remembered"] boolValue] ? localize(@" [本次启动的缓存；可能已拔线]", @" [Cached this boot; may be unplugged]").UTF8String :
               [row[@"virtual"] boolValue] ? localize(@" [虚拟]", @" [Virtual]").UTF8String : "");
    }
}

// Pure planning: also exercised by the fixture tests below.
static NSArray<NSDictionary *> *plan(NSArray<NSDictionary *> *rows, NSString *action,
                                    NSString *target, BOOL allowAllOff, NSString **error) {
    BOOL group = [@[@"builtin", @"external", @"all"] containsObject:target];
    unsigned long long numeric = 0;
    if (!group) {
        NSScanner *scanner = [NSScanner scannerWithString:target];
        scanner.charactersToBeSkipped = nil;
        if (![scanner scanUnsignedLongLong:&numeric] || !scanner.isAtEnd ||
            numeric == 0 || numeric > UINT32_MAX) {
            *error = localize(@"目标必须是 builtin、external、all 或有效的数字显示器 ID。", @"Target must be builtin, external, all, or a valid numeric display ID.");
            return nil;
        }
    }
    NSMutableArray *changes = [NSMutableArray array];
    NSUInteger selected = 0, remaining = 0;
    BOOL exclusive = NO;
    for (NSDictionary *row in rows) {
        if ([row[@"enabled"] boolValue] && [row[@"exclusive"] boolValue]) exclusive = YES;
        BOOL matches = [target isEqual:@"all"] ||
                       ([target isEqual:@"builtin"] && [row[@"builtin"] boolValue]) ||
                       ([target isEqual:@"external"] && ![row[@"builtin"] boolValue]) ||
                       (!group && [row[@"id"] unsignedIntValue] == numeric);
        BOOL current = [row[@"enabled"] boolValue];
        BOOL desired = current;
        if (matches) {
            selected++;
            desired = [action isEqual:@"toggle"] ? !current : [action isEqual:@"on"];
            if (current != desired) {
                if (!desired && [row[@"remembered"] boolValue]) {
                    *error = localize(@"无法停用仅在缓存中存在的显示器。", @"Cannot disable a display that exists only in the cache.");
                    return nil;
                }
                [changes addObject:@{@"display": row, @"enabled": @(desired)}];
            }
        }
        // An enable request is not proof that a second screen will become usable.
        if (current && desired && ![row[@"virtual"] boolValue] &&
            ![row[@"remembered"] boolValue]) remaining++;
    }
    if (!selected) {
        *error = localize(@"没有找到目标显示器。先运行 list 查看 ID。", @"Target display not found. Run list to check IDs.");
        return nil;
    }
    BOOL disables = NO;
    for (NSDictionary *change in changes) {
        if (![change[@"enabled"] boolValue]) disables = YES;
        else if (exclusive) {
            *error = localize(@"系统处于独占虚拟显示模式，暂不能启用物理显示器。", @"Cannot enable physical displays while an exclusive virtual display is active.");
            return nil;
        }
    }
    if (disables && !allowAllOff && remaining == 0) {
        *error = localize(@"操作会停用最后一块可用的非虚拟屏，已取消。需要明确允许时加 --allow-all-off。", @"This would disable the last usable non-virtual display. Cancelled; use --allow-all-off to explicitly allow it.");
        return nil;
    }
    return changes;
}

static BOOL apply(NSArray *changes, NSString **error) {
    CGDisplayConfigRef config = NULL;
    CGError status = CGBeginDisplayConfiguration(&config);
    if (status != kCGErrorSuccess) {
        *error = [NSString stringWithFormat:localize(@"创建显示配置事务失败（CGError=%d）。", @"Unable to begin display configuration (CGError=%d)."), status];
        return NO;
    }
    for (NSDictionary *change in changes) {
        uint32_t identifier = [change[@"display"][@"id"] unsignedIntValue];
        status = configureEnabled(config, identifier, [change[@"enabled"] boolValue]);
        if (status != kCGErrorSuccess) {
            CGCancelDisplayConfiguration(config);
            *error = [NSString stringWithFormat:localize(@"配置显示器 %u 失败（CGError=%d），事务已取消。", @"Unable to configure display %u (CGError=%d). Transaction cancelled."), identifier, status];
            return NO;
        }
    }
    status = CGCompleteDisplayConfiguration(config, kCGConfigureForSession);
    if (status != kCGErrorSuccess) {
        *error = [NSString stringWithFormat:localize(@"提交显示配置失败（CGError=%d）。", @"Unable to commit display configuration (CGError=%d)."), status];
        return NO;
    }
    return YES;
}

typedef struct {
    double missingSince;
    double lastScan;
    double nextAttempt;
    unsigned attempts;
} GuardState;

static GuardState newGuardState(void) {
    return (GuardState){ .missingSince = -1, .lastScan = -1, .nextAttempt = 0, .attempts = 0 };
}

// Only an explicitly open lid permits recovery. Unknown never means open.
static int lidState(void) {
    io_service_t root = IOServiceGetMatchingService(kIOMainPortDefault,
                                                   IOServiceMatching("IOPMrootDomain"));
    if (!root) return -1;
    CFTypeRef value = IORegistryEntryCreateCFProperty(root, CFSTR(kAppleClamshellStateKey),
                                                     kCFAllocatorDefault, 0);
    IOObjectRelease(root);
    if (!value) return -1;
    int result = -1;
    if (CFGetTypeID(value) == CFBooleanGetTypeID())
        result = CFBooleanGetValue(value) ? 1 : 0;
    CFRelease(value);
    return result;
}

// Pure, time-driven policy. It can only produce enable requests for built-ins.
static NSArray *recoveryPlan(NSArray *rows, int lid, double now,
                            GuardState *state, NSString **reason) {
    // A long scan gap can be sleep or a suspended process: start a new grace period.
    if (state->lastScan >= 0 && now - state->lastScan > 15) state->missingSince = -1;
    state->lastScan = now;
    BOOL available = NO, external = NO, exclusive = NO;
    NSMutableArray *changes = [NSMutableArray array];
    for (NSDictionary *row in rows) {
        BOOL enabled = [row[@"enabled"] boolValue] && ![row[@"remembered"] boolValue];
        if (enabled && [row[@"exclusive"] boolValue]) exclusive = YES;
        if (enabled && ![row[@"virtual"] boolValue]) {
            available = YES;
            if (![row[@"builtin"] boolValue]) external = YES;
        }
        if ([row[@"builtin"] boolValue] && ![row[@"virtual"] boolValue] && !enabled)
            [changes addObject:@{@"display": row, @"enabled": @YES}];
    }
    if (external) {
        state->missingSince = -1;
        state->attempts = 0;
        state->nextAttempt = 0;
        *reason = @"external-available";
    } else if (available) {
        state->missingSince = -1;
        *reason = @"builtin-available";
    } else if (lid != 0) {
        state->missingSince = -1;
        *reason = lid == 1 ? @"lid-closed" : @"lid-unknown";
    } else if (exclusive) {
        state->missingSince = -1;
        *reason = @"exclusive-virtual-display";
    } else if (!changes.count) {
        state->missingSince = -1;
        *reason = @"no-known-builtin";
    } else {
        if (state->missingSince < 0) state->missingSince = now;
        if (now - state->missingSince < 1) *reason = @"waiting-for-stability";
        else if (now < state->nextAttempt) *reason = @"retry-cooldown";
        else { *reason = @"recover-builtin"; return changes; }
    }
    return @[];
}

static void recoveryAttempted(GuardState *state, double now) {
    state->attempts++;
    // Avoid a rapid fight with another display manager or an unsupported panel.
    if (state->attempts >= 3) {
        state->attempts = 0;
        state->nextAttempt = now + 60;
    } else state->nextAttempt = now + 10;
}

static void guardLog(NSString *message) {
    fprintf(stderr, "%s macDisplayCtl-guard: %s\n",
            [NSDate.date.description UTF8String], message.UTF8String);
    fflush(stderr);
}

static NSString *builtinKey(NSDictionary *row) {
    id uuid = row[@"uuid"];
    if ([uuid isKindOfClass:NSString.class] && [uuid length]) return uuid;
    return [NSString stringWithFormat:@"id:%u", [row[@"id"] unsignedIntValue]];
}

static BOOL usableExternal(NSArray *rows) {
    for (NSDictionary *row in rows)
        if ([row[@"enabled"] boolValue] && ![row[@"remembered"] boolValue] &&
            ![row[@"builtin"] boolValue] && ![row[@"virtual"] boolValue]) return YES;
    return NO;
}

// User preference is frozen across an unplug/replug cycle, independently of recovery.
@interface ReconnectMemory : NSObject
@property(strong) NSMutableDictionary<NSString *, NSNumber *> *preferences;
@property(strong) NSMutableDictionary<NSString *, NSString *> *manualTokens;
@property(strong) NSMutableSet<NSString *> *manualPendingKeys;
@property BOOL externalWasAvailable;
@property BOOL pendingReconnect;
@property double externalStableSince;
- (NSArray *)observe:(NSArray *)rows lid:(int)lid now:(double)now reason:(NSString **)reason;
- (void)acceptManualIntents:(NSDictionary *)intents;
@end

@implementation ReconnectMemory
- (instancetype)init {
    if ((self = [super init])) {
        _preferences = [NSMutableDictionary dictionary];
        _manualTokens = [NSMutableDictionary dictionary];
        _manualPendingKeys = [NSMutableSet set];
        _externalStableSince = -1;
    }
    return self;
}
- (NSArray *)observe:(NSArray *)rows lid:(int)lid now:(double)now reason:(NSString **)reason {
    if (!usableExternal(rows)) {
        if (self.externalWasAvailable) self.pendingReconnect = YES;
        self.externalWasAvailable = NO;
        self.externalStableSince = -1;
        return @[];
    }
    if (!self.externalWasAvailable || self.externalStableSince < 0)
        self.externalStableSince = now;
    self.externalWasAvailable = YES;
    if (self.pendingReconnect) {
        if (lid != 0) {
            *reason = lid == 1 ? @"reconnect-lid-closed" : @"reconnect-lid-unknown";
            return @[];
        }
        if (now - self.externalStableSince < 2) {
            *reason = @"waiting-for-external-stability";
            return @[];
        }
        NSMutableArray *changes = [NSMutableArray array];
        NSUInteger matched = 0;
        for (NSDictionary *row in rows) {
            if (![row[@"builtin"] boolValue] || [row[@"virtual"] boolValue]) continue;
            NSNumber *desired = self.preferences[builtinKey(row)];
            if (!desired) continue;
            matched++;
            if (desired.boolValue == [row[@"enabled"] boolValue]) continue;
            NSString *error = nil;
            NSArray *safe = plan(rows, desired.boolValue ? @"on" : @"off",
                                 [row[@"id"] stringValue], NO, &error);
            if (!safe) { *reason = @"reconnect-restore-blocked"; return @[]; }
            [changes addObjectsFromArray:safe];
        }
        if (changes.count) {
            *reason = @"restore-builtin-preference";
            return changes;
        }
        if (!matched && self.preferences.count) {
            *reason = @"reconnect-no-matching-builtin";
            return @[];
        }
        // Only observed agreement completes the episode, not transaction submission.
        self.pendingReconnect = NO;
    }
    if (lid == 0) {
        for (NSDictionary *row in rows) {
            if ([row[@"builtin"] boolValue] && ![row[@"virtual"] boolValue] &&
                ![row[@"remembered"] boolValue]) {
                NSString *key = builtinKey(row);
                NSNumber *current = @([row[@"enabled"] boolValue]);
                if ([self.manualPendingKeys containsObject:key]) {
                    if ([self.preferences[key] isEqual:current]) [self.manualPendingKeys removeObject:key];
                    else continue;
                }
                self.preferences[key] = current;
            }
        }
    }
    return @[];
}
- (void)acceptManualIntents:(NSDictionary *)intents {
    for (id key in intents) {
        id value = intents[key];
        if (![key isKindOfClass:NSString.class] || ![value isKindOfClass:NSDictionary.class] ||
            ![value[@"token"] isKindOfClass:NSString.class] ||
            ![value[@"enabled"] isKindOfClass:NSNumber.class]) continue;
        if (![self.manualTokens[key] isEqual:value[@"token"]]) {
            self.preferences[key] = value[@"enabled"];
            self.manualTokens[key] = value[@"token"];
            [self.manualPendingKeys addObject:key];
        }
    }
}
@end

static NSString *sessionPath(NSString *name) {
    return [[cachePath() stringByDeletingLastPathComponent] stringByAppendingPathComponent:name];
}

static NSDictionary *readSessionFile(NSString *name) {
    NSData *data = [NSData dataWithContentsOfFile:sessionPath(name)];
    if (!data) return @{};
    id object = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![object isKindOfClass:NSDictionary.class] || ![object[@"boot"] isEqual:bootID()]) return @{};
    return object;
}

static BOOL writeSessionFile(NSString *name, NSDictionary *value, NSString **error) {
    NSString *boot = bootID();
    if (!boot) { *error = localize(@"无法记录显示器设置。", @"Unable to save display settings."); return NO; }
    NSMutableDictionary *object = [value mutableCopy];
    object[@"boot"] = boot;
    NSError *failure = nil;
    NSString *directory = [cachePath() stringByDeletingLastPathComponent];
    if (![[NSFileManager defaultManager] createDirectoryAtPath:directory withIntermediateDirectories:YES
                                                  attributes:nil error:&failure]) {
        *error = failure.localizedDescription; return NO;
    }
    NSData *data = [NSJSONSerialization dataWithJSONObject:object options:NSJSONWritingPrettyPrinted error:&failure];
    if (!data || ![data writeToFile:sessionPath(name) options:NSDataWritingAtomic error:&failure]) {
        *error = failure.localizedDescription; return NO;
    }
    return YES;
}

static ReconnectMemory *memoryFromSnapshot(NSDictionary *saved) {
    ReconnectMemory *memory = [ReconnectMemory new];
    id preferences = saved[@"preferences"], tokens = saved[@"manualTokens"];
    if ([preferences isKindOfClass:NSDictionary.class]) {
        for (id key in preferences)
            if ([key isKindOfClass:NSString.class] && [preferences[key] isKindOfClass:NSNumber.class])
                memory.preferences[key] = preferences[key];
    }
    if ([tokens isKindOfClass:NSDictionary.class]) {
        for (id key in tokens)
            if ([key isKindOfClass:NSString.class] && [tokens[key] isKindOfClass:NSString.class])
                memory.manualTokens[key] = tokens[key];
    }
    id pending = saved[@"manualPendingKeys"];
    if ([pending isKindOfClass:NSArray.class])
        for (id key in pending) if ([key isKindOfClass:NSString.class]) [memory.manualPendingKeys addObject:key];
    memory.externalWasAvailable = [saved[@"externalWasAvailable"] boolValue];
    memory.pendingReconnect = [saved[@"pendingReconnect"] boolValue];
    return memory;
}

static ReconnectMemory *loadReconnectMemory(void) {
    return memoryFromSnapshot(readSessionFile(@"guard-state.json"));
}

static NSDictionary *reconnectSnapshot(ReconnectMemory *memory) {
    return @{@"preferences": [memory.preferences copy], @"manualTokens": [memory.manualTokens copy],
             @"manualPendingKeys": [[memory.manualPendingKeys allObjects] sortedArrayUsingSelector:@selector(compare:)],
             @"externalWasAvailable": @(memory.externalWasAvailable),
             @"pendingReconnect": @(memory.pendingReconnect)};
}

static void importManualIntent(ReconnectMemory *memory) {
    id intents = readSessionFile(@"builtin-intent.json")[@"intents"];
    if (![intents isKindOfClass:NSDictionary.class]) return;
    [memory acceptManualIntents:intents];
}

static void recordBuiltinIntent(NSArray *rows, NSString *action, NSString *target) {
    NSMutableDictionary *intents = [NSMutableDictionary dictionary];
    id previous = readSessionFile(@"builtin-intent.json")[@"intents"];
    if ([previous isKindOfClass:NSDictionary.class]) [intents addEntriesFromDictionary:previous];
    BOOL changed = NO;
    for (NSDictionary *row in rows) {
        if (![row[@"builtin"] boolValue] || [row[@"virtual"] boolValue]) continue;
        BOOL selected = [target isEqual:@"builtin"] || [target isEqual:@"all"] ||
                        ([target longLongValue] > 0 && [target longLongValue] == [row[@"id"] longLongValue]);
        if (!selected) continue;
        BOOL desired = [action isEqual:@"toggle"] ? ![row[@"enabled"] boolValue] : [action isEqual:@"on"];
        intents[builtinKey(row)] = @{@"enabled": @(desired), @"token": NSUUID.UUID.UUIDString};
        changed = YES;
    }
    if (changed) {
        NSString *error = nil;
        if (!writeSessionFile(@"builtin-intent.json", @{@"intents": intents}, &error))
            fprintf(stderr, localize(@"内屏操作已完成，但偏好记录失败：%s\n", @"Built-in display operation completed, but saving its preference failed: %s\n").UTF8String, error.UTF8String);
    }
}

static int operationLock(BOOL wait, NSString **error) {
    NSError *failure = nil;
    NSString *directory = [cachePath() stringByDeletingLastPathComponent];
    if (![[NSFileManager defaultManager] createDirectoryAtPath:directory withIntermediateDirectories:YES
                                                  attributes:nil error:&failure]) {
        *error = failure.localizedDescription; return -1;
    }
    int fd = open([sessionPath(@"projection.lock") fileSystemRepresentation], O_CREAT | O_RDWR | O_CLOEXEC, 0600);
    if (fd < 0) { *error = localize(@"无法创建屏幕切换锁。", @"Unable to create the display operation lock."); return -1; }
    for (int i = 0; i < (wait ? 50 : 1); i++) {
        if (flock(fd, LOCK_EX | LOCK_NB) == 0) return fd;
        if (wait) usleep(100000);
    }
    close(fd); *error = localize(@"另一个屏幕切换正在进行，请稍后重试。", @"Another display operation is in progress. Try again shortly."); return -1;
}

// Layouts outlive helper processes and reboots. Numeric IDs are only safe this boot.
static NSString *layoutIdentity(NSDictionary *row, NSString *boot) {
    id uuid = row[@"uuid"];
    if ([uuid isKindOfClass:NSString.class] && [uuid length]) return [@"uuid:" stringByAppendingString:uuid];
    if (!boot.length || ![row[@"id"] isKindOfClass:NSNumber.class]) return nil;
    return [NSString stringWithFormat:@"boot:%@:%@", boot, row[@"id"]];
}

static NSString *layoutKey(NSDictionary *builtin, NSDictionary *external, NSString *boot) {
    NSString *first = layoutIdentity(builtin, boot), *second = layoutIdentity(external, boot);
    if (!first || !second) return nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:@[first, second] options:0 error:nil];
    return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
}

static BOOL validOrigin(id origin) {
    if (![origin isKindOfClass:NSDictionary.class]) return NO;
    for (NSString *axis in @[@"x", @"y"]) {
        id value = origin[axis];
        if (![value isKindOfClass:NSNumber.class]) return NO;
        double number = [value doubleValue];
        if (!isfinite(number) || number < INT32_MIN || number > INT32_MAX || trunc(number) != number) return NO;
    }
    return YES;
}

static BOOL extendedDisplay(NSDictionary *row) {
    return [row[@"enabled"] boolValue] && ![row[@"remembered"] boolValue] &&
           ![row[@"virtual"] boolValue] && ![row[@"mirror"] boolValue] &&
           ![row[@"mirrorOf"] unsignedIntValue] && validOrigin(row);
}

static NSDictionary *captureLayout(NSDictionary *builtin, NSDictionary *external) {
    if (!extendedDisplay(builtin) || !extendedDisplay(external)) return nil;
    double bx = [builtin[@"x"] doubleValue], by = [builtin[@"y"] doubleValue];
    double ex = [external[@"x"] doubleValue], ey = [external[@"y"] doubleValue];
    // Mirroring or an unfinished reconfiguration can report coincident origins.
    if (bx == ex && by == ey) return nil;
    double anchorX = [external[@"main"] boolValue] ? ex : bx;
    double anchorY = [external[@"main"] boolValue] ? ey : by;
    NSDictionary *layout = @{@"builtin": @{@"x": @(bx - anchorX), @"y": @(by - anchorY)},
                             @"external": @{@"x": @(ex - anchorX), @"y": @(ey - anchorY)}};
    return validOrigin(layout[@"builtin"]) && validOrigin(layout[@"external"]) ? layout : nil;
}

static NSDictionary *updatedLayouts(NSDictionary *previous, NSArray *rows, NSString *boot) {
    NSMutableDictionary *layouts = [previous mutableCopy];
    NSDictionary *builtin = nil;
    for (NSDictionary *row in rows) if ([row[@"builtin"] boolValue] && ![row[@"virtual"] boolValue]) builtin = row;
    if (!builtin) return layouts;
    for (NSDictionary *row in rows) {
        if ([row[@"builtin"] boolValue]) continue;
        NSString *key = layoutKey(builtin, row, boot);
        NSDictionary *layout = captureLayout(builtin, row);
        if (key && layout) layouts[key] = layout;
    }
    return layouts;
}

static NSDictionary *loadLayouts(void) {
    NSData *data = [NSData dataWithContentsOfFile:sessionPath(@"extended-layouts.json")];
    id object = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    if (![object isKindOfClass:NSDictionary.class] || ![object[@"version"] isEqual:@1] ||
        ![object[@"layouts"] isKindOfClass:NSDictionary.class]) return @{};
    return object[@"layouts"];
}

static NSDictionary *savedLayout(NSDictionary *layouts, NSDictionary *configuration, NSString *boot) {
    NSString *key = layoutKey(configuration[@"builtin"], configuration[@"external"], boot);
    id layout = key ? layouts[key] : nil;
    if (![layout isKindOfClass:NSDictionary.class] ||
        !validOrigin(layout[@"builtin"]) || !validOrigin(layout[@"external"])) return nil;
    // One of the two selected screens must remain the main display at (0, 0).
    BOOL builtinMain = [layout[@"builtin"][@"x"] intValue] == 0 && [layout[@"builtin"][@"y"] intValue] == 0;
    BOOL externalMain = [layout[@"external"][@"x"] intValue] == 0 && [layout[@"external"][@"y"] intValue] == 0;
    return builtinMain != externalMain ? layout : nil;
}

// Choose only one second screen; leave unrelated virtual displays untouched.
static NSDictionary *projectionPlan(NSArray *rows, NSString *mode, NSNumber *externalID, NSString **error) {
    if (![@[@"internal", @"duplicate", @"extend", @"external"] containsObject:mode]) {
        *error = localize(@"未知投影模式。", @"Unknown projection mode."); return nil;
    }
    NSDictionary *builtin = nil, *external = nil;
    NSMutableArray *externals = [NSMutableArray array];
    for (NSDictionary *row in rows) {
        if ([row[@"enabled"] boolValue] && [row[@"exclusive"] boolValue]) {
            *error = localize(@"系统处于独占虚拟显示模式，暂不能切换。", @"Cannot switch modes while an exclusive virtual display is active."); return nil;
        }
        if ([row[@"virtual"] boolValue]) continue;
        if ([row[@"builtin"] boolValue]) builtin = row;
        else [externals addObject:row];
    }
    if (!builtin) { *error = localize(@"未找到内置屏，当前仅支持带内置屏的 Mac。", @"Built-in display not found. Projection modes require a Mac with a built-in display."); return nil; }
    for (NSDictionary *row in externals) {
        if (externalID) {
            if ([row[@"id"] isEqual:externalID]) { external = row; break; }
        } else if (!external || ([row[@"enabled"] boolValue] && ![external[@"enabled"] boolValue]) ||
                   ([external[@"remembered"] boolValue] && ![row[@"remembered"] boolValue])) external = row;
    }
    if (![mode isEqual:@"internal"] && !external) {
        *error = localize(@"未找到第二屏幕，请先接入外置显示器。", @"Second display not found. Connect an external display first."); return nil;
    }
    if (![mode isEqual:@"internal"] && [external[@"connected"] isEqual:@NO]) {
        *error = localize(@"请先连接外接显示器，再选择此模式。", @"Connect an external display before selecting this mode."); return nil;
    }
    return @{@"mode": mode, @"builtin": builtin, @"external": external ?: @{}, @"externals": externals};
}

static BOOL isEnabled(CGDirectDisplayID identifier) {
    return CGDisplayIsOnline(identifier) && (CGDisplayIsActive(identifier) ||
           CGDisplayIsInMirrorSet(identifier) || CGDisplayIsInHWMirrorSet(identifier));
}

static BOOL waitEnabled(CGDirectDisplayID identifier) {
    for (int i = 0; i < 30; i++) {
        if (isEnabled(identifier)) return YES;
        usleep(100000);
    }
    return NO;
}

static NSDictionary *projectionOrigins(NSDictionary *configuration, int32_t builtinWidth) {
    NSString *mode = configuration[@"mode"];
    NSDictionary *layout = [mode isEqual:@"extend"] ? configuration[@"layout"] : nil;
    if (layout) return layout;
    return @{@"builtin": @{@"x": @0, @"y": @0},
             @"external": @{@"x": [mode isEqual:@"extend"] ? @(builtinWidth) : @0, @"y": @0}};
}

static BOOL projectionLayout(NSDictionary *configuration, NSString **error) {
    NSString *mode = configuration[@"mode"];
    CGDirectDisplayID internal = [configuration[@"builtin"][@"id"] unsignedIntValue];
    CGDirectDisplayID external = [configuration[@"external"][@"id"] unsignedIntValue];
    BOOL internalOnly = [mode isEqual:@"internal"], externalOnly = [mode isEqual:@"external"];
    BOOL duplicate = [mode isEqual:@"duplicate"];
    // The surviving screen must be usable BEFORE disabling any screen.
    CGDirectDisplayID survivor = externalOnly ? external : internal;
    if (!isEnabled(survivor) || (!internalOnly && !externalOnly && !isEnabled(external))) {
        *error = localize(@"目标屏幕尚不可用，保留当前屏幕。", @"Target display is not yet usable. Keeping the current display."); return NO;
    }
    CGDisplayConfigRef config = NULL;
    CGError status = CGBeginDisplayConfiguration(&config);
    if (status != kCGErrorSuccess) { *error = localize(@"无法创建显示布局事务。", @"Unable to begin the display layout transaction."); return NO; }
    if (isEnabled(internal)) status = CGConfigureDisplayMirrorOfDisplay(config, internal, kCGNullDirectDisplay);
    for (NSDictionary *row in configuration[@"externals"]) {
        uint32_t identifier = [row[@"id"] unsignedIntValue];
        if (!isEnabled(identifier)) continue;
        if (status == kCGErrorSuccess)
            status = CGConfigureDisplayMirrorOfDisplay(config, identifier, kCGNullDirectDisplay);
    }
    if (status == kCGErrorSuccess && duplicate)
        status = CGConfigureDisplayMirrorOfDisplay(config, external, internal);
    NSDictionary *origins = projectionOrigins(configuration, (int32_t)CGDisplayBounds(internal).size.width);
    if (status == kCGErrorSuccess && !externalOnly)
        status = CGConfigureDisplayOrigin(config, internal, [origins[@"builtin"][@"x"] intValue], [origins[@"builtin"][@"y"] intValue]);
    if (status == kCGErrorSuccess && !internalOnly && !duplicate)
        status = CGConfigureDisplayOrigin(config, external, [origins[@"external"][@"x"] intValue], [origins[@"external"][@"y"] intValue]);
    if (status == kCGErrorSuccess && externalOnly && isEnabled(internal))
        status = configureEnabled(config, internal, false);
    for (NSDictionary *row in configuration[@"externals"]) {
        uint32_t identifier = [row[@"id"] unsignedIntValue];
        if (!isEnabled(identifier) || (!internalOnly && identifier == external)) continue;
        if (status == kCGErrorSuccess) status = configureEnabled(config, identifier, false);
    }
    if (status != kCGErrorSuccess) {
        CGCancelDisplayConfiguration(config);
        *error = [NSString stringWithFormat:localize(@"布局配置失败（CGError=%d），保留当前可用屏幕。", @"Unable to configure the layout (CGError=%d). Keeping currently usable displays."), status]; return NO;
    }
    status = CGCompleteDisplayConfiguration(config, kCGConfigureForSession);
    if (status != kCGErrorSuccess) {
        *error = [NSString stringWithFormat:localize(@"布局提交失败（CGError=%d）。", @"Unable to commit the layout (CGError=%d)."), status]; return NO;
    }
    return YES;
}

static BOOL projectionMatches(NSDictionary *configuration) {
    NSString *mode = configuration[@"mode"];
    uint32_t internal = [configuration[@"builtin"][@"id"] unsignedIntValue];
    uint32_t external = [configuration[@"external"][@"id"] unsignedIntValue];
    BOOL internalOnly = [mode isEqual:@"internal"], externalOnly = [mode isEqual:@"external"];
    if (isEnabled(internal) != !externalOnly) return NO;
    if (!internalOnly && !isEnabled(external)) return NO;
    for (NSDictionary *row in configuration[@"externals"]) {
        uint32_t identifier = [row[@"id"] unsignedIntValue];
        if ((internalOnly || identifier != external) && isEnabled(identifier)) return NO;
    }
    if ([mode isEqual:@"duplicate"])
        return CGDisplayMirrorsDisplay(external) == internal || CGDisplayMirrorsDisplay(internal) == external;
    if ([mode isEqual:@"extend"]) {
        NSDictionary *layout = configuration[@"layout"];
        if (layout) {
            CGPoint first = CGDisplayBounds(internal).origin, second = CGDisplayBounds(external).origin;
            if (first.x != [layout[@"builtin"][@"x"] intValue] || first.y != [layout[@"builtin"][@"y"] intValue] ||
                second.x != [layout[@"external"][@"x"] intValue] || second.y != [layout[@"external"][@"y"] intValue]) return NO;
        }
        return !CGDisplayIsInMirrorSet(internal) && !CGDisplayIsInMirrorSet(external) &&
               !CGDisplayIsInHWMirrorSet(internal) && !CGDisplayIsInHWMirrorSet(external);
    }
    return YES;
}

static int project(NSArray *initialRows, NSString *mode, NSNumber *externalID, BOOL dryRun) {
    NSString *error = nil;
    int fd = -1;
    if (!dryRun) {
        fd = operationLock(YES, &error);
        if (fd < 0) { fail(error); return 1; }
    }
    @try {
        NSArray *rows = dryRun ? initialRows : discover(&error);
        if (!rows) { fail(error); return 1; }
        NSMutableDictionary *configuration = [projectionPlan(rows, mode, externalID, &error) mutableCopy];
        if (!configuration) { fail(error); return 2; }
        NSDictionary *previousLayouts = loadLayouts();
        NSDictionary *layouts = updatedLayouts(previousLayouts, rows, bootID());
        NSDictionary *layout = savedLayout(layouts, configuration, bootID());
        if ([mode isEqual:@"extend"] && layout) configuration[@"layout"] = layout;
        if (dryRun) {
            NSData *data = [NSJSONSerialization dataWithJSONObject:configuration options:NSJSONWritingPrettyPrinted error:nil];
            fwrite(data.bytes, 1, data.length, stdout); putchar('\n'); return 0;
        }
        BOOL externalOnly = [mode isEqual:@"external"], internalOnly = [mode isEqual:@"internal"];
        if (!externalOnly && lidState() != 0) {
            fail(localize(@"请先打开笔记本屏幕，再选择包含内置屏的模式。", @"Open the laptop lid before selecting a mode that uses the built-in display.")); return 2;
        }
        // Save before enabling, mirroring, or disabling can destroy the original origins.
        if (![layouts isEqual:previousLayouts] &&
            !writeSessionFile(@"extended-layouts.json", @{@"version": @1, @"layouts": layouts}, &error)) {
            fail(error); return 1;
        }
        if (!saveRemembered(rows, &error)) { fail(error); return 1; }
        if (projectionMatches(configuration)) {
            recordBuiltinIntent(rows, externalOnly ? @"off" : @"on", @"builtin");
            puts(localize(@"已经处于所选屏幕模式。", @"The selected display mode is already active.").UTF8String); return 0;
        }
        NSMutableArray *enable = [NSMutableArray array];
        if (!externalOnly && ![configuration[@"builtin"][@"enabled"] boolValue])
            [enable addObject:@{@"display": configuration[@"builtin"], @"enabled": @YES}];
        if (!internalOnly && ![configuration[@"external"][@"enabled"] boolValue])
            [enable addObject:@{@"display": configuration[@"external"], @"enabled": @YES}];
        if (enable.count && !apply(enable, &error)) { fail(error); return 1; }
        uint32_t internal = [configuration[@"builtin"][@"id"] unsignedIntValue];
        uint32_t external = [configuration[@"external"][@"id"] unsignedIntValue];
        if ((!externalOnly && !waitEnabled(internal)) || (!internalOnly && !waitEnabled(external))) {
            fail(localize(@"目标屏幕未能启用，未停用当前屏幕。请检查连接后重试。", @"The target display could not be enabled. The current display was kept enabled. Check the connection and retry.")); return 3;
        }
        // With no history, retain an arrangement restored by macOS on re-enabling.
        if ([mode isEqual:@"extend"] && !configuration[@"layout"]) {
            NSArray *enabledRows = discover(&error);
            NSDictionary *enabledPlan = enabledRows ? projectionPlan(enabledRows, mode, @(external), &error) : nil;
            NSDictionary *systemLayout = enabledPlan ? captureLayout(enabledPlan[@"builtin"], enabledPlan[@"external"]) : nil;
            if (systemLayout) configuration[@"layout"] = systemLayout;
        }
        if (!projectionLayout(configuration, &error)) { fail(error); return 1; }
        recordBuiltinIntent(rows, externalOnly ? @"off" : @"on", @"builtin");
        for (int i = 0; i < 30; i++) {
            if (projectionMatches(configuration)) { puts(localize(@"屏幕模式切换完成。", @"Display mode switched.").UTF8String); return 0; }
            usleep(100000);
        }
        fail(localize(@"配置已提交，系统状态尚未确认；请刷新查看当前模式。", @"Configuration committed, but the system state is not yet confirmed. Refresh to check the current mode.")); return 3;
    } @finally { if (fd >= 0) close(fd); }
}

#ifndef DISPLAYCTL_TEST
@interface DisplayGuard : NSObject {
    GuardState _state;
}
@property BOOL dryRun;
@property BOOL pendingCheck;
@property(copy) NSArray *lastSavedRows;
@property(copy) NSString *lastError;
@property(copy) NSString *lastReason;
@property(strong) ReconnectMemory *memory;
@property(copy) NSDictionary *lastSavedMemory;
@property double nextRestoreAttempt;
- (void)check;
- (void)checkUnlocked;
@end

@implementation DisplayGuard
- (instancetype)init {
    if ((self = [super init])) {
        _state = newGuardState();
        _memory = loadReconnectMemory();
    }
    return self;
}
- (void)check {
    if (self.dryRun) { [self checkUnlocked]; return; }
    NSString *error = nil;
    int fd = operationLock(NO, &error);
    if (fd < 0) return; // Projection is in progress; periodic check will retry.
    @try { [self checkUnlocked]; } @finally { close(fd); }
}
- (void)checkUnlocked {
    @autoreleasepool {
        NSString *error = nil;
        NSArray *rows = discover(&error);
        if (!rows) {
            _state.missingSince = -1;
            if (![error isEqual:self.lastError]) guardLog(error);
            self.lastError = error;
            return;
        }
        if (!self.dryRun && ![rows isEqual:self.lastSavedRows]) {
            if (!saveRemembered(rows, &error)) {
                _state.missingSince = -1;
                if (![error isEqual:self.lastError]) guardLog(error);
                self.lastError = error;
                return;
            }
            self.lastSavedRows = rows;
        }
        self.lastError = nil;
        NSString *reason = nil;
        double now = NSProcessInfo.processInfo.systemUptime;
        int lid = lidState();
        if (_state.lastScan >= 0 && now - _state.lastScan > 15 && self.memory.preferences.count) {
            self.memory.pendingReconnect = YES;
            self.memory.externalStableSince = -1;
        }
        importManualIntent(self.memory);
        NSString *restoreReason = nil;
        NSArray *restore = [self.memory observe:rows lid:lid now:now reason:&restoreReason];
        NSDictionary *snapshot = reconnectSnapshot(self.memory);
        if (!self.dryRun && ![snapshot isEqual:self.lastSavedMemory]) {
            if (!writeSessionFile(@"guard-state.json", snapshot, &error)) {
                _state.missingSince = -1;
                if (![error isEqual:self.lastError]) guardLog(error);
                self.lastError = error;
                return;
            }
            self.lastSavedMemory = snapshot;
        }
        NSArray *changes = recoveryPlan(rows, lid, now, &_state, &reason);
        BOOL restoring = restore.count > 0;
        if (restoring) {
            if (now < self.nextRestoreAttempt) { restore = @[]; restoring = NO; restoreReason = @"restore-retry-cooldown"; }
            else changes = restore;
        }
        if (restoreReason) reason = restoreReason;
        if (![reason isEqual:self.lastReason]) {
            guardLog([NSString stringWithFormat:localize(@"状态：%@%@", @"State: %@%@"), reason, self.dryRun ? localize(@"（只读）", @" (read-only)") : @""]);
            self.lastReason = reason;
        }
        if (([reason isEqual:@"waiting-for-stability"] ||
             [reason isEqual:@"waiting-for-external-stability"]) && !self.pendingCheck) {
            self.pendingCheck = YES;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
                self.pendingCheck = NO;
                [self check];
            });
        }
        if (!changes.count) return;
        // Read all state again immediately before committing; don't act on an old event.
        NSArray *fresh = discover(&error);
        if (!fresh) { _state.missingSince = -1; return; }
        now = NSProcessInfo.processInfo.systemUptime;
        importManualIntent(self.memory);
        if (restoring) {
            changes = [self.memory observe:fresh lid:lidState() now:now reason:&reason];
        } else {
            [self.memory observe:fresh lid:lidState() now:now reason:&restoreReason];
            changes = recoveryPlan(fresh, lidState(), now, &_state, &reason);
        }
        if (!changes.count) return;
        if (restoring) self.nextRestoreAttempt = now + 10;
        else recoveryAttempted(&_state, now);
        if (self.dryRun) {
            guardLog(restoring ? localize(@"预览：外屏已稳定，将恢复内屏之前的状态。", @"Preview: external display is stable; restore the previous built-in display state.") :
                               localize(@"预览：没有可用实体屏且已开盖，将只启用内置屏。", @"Preview: no usable physical display and the lid is open; enable only the built-in display."));
            return;
        }
        if (!saveRemembered(fresh, &error) || !apply(changes, &error)) {
            guardLog([NSString stringWithFormat:localize(@"恢复失败，稍后重试：%@", @"Recovery failed; will retry: %@"), error]);
        } else {
            guardLog(restoring ? localize(@"已提交恢复内屏原状态的事务，将继续核对；外屏保持启用。", @"Built-in display restoration committed; verification will continue. External displays remain enabled.") :
                               localize(@"内置屏兜底启用事务已提交；保留原偏好，外屏回来后恢复。", @"Built-in display recovery committed. Previous preference is retained for reconnection."));
        }
    }
}
@end

static void displayChanged(CGDirectDisplayID display, CGDisplayChangeSummaryFlags flags, void *context) {
    (void)display;
    if (flags & kCGDisplayBeginConfigurationFlag) return;
    DisplayGuard *guard = (__bridge DisplayGuard *)context;
    dispatch_async(dispatch_get_main_queue(), ^{ [guard check]; });
}

static void powerChanged(void *context, io_service_t service, natural_t message, void *argument) {
    (void)service; (void)argument;
    if (message != kIOPMMessageClamshellStateChange) return;
    DisplayGuard *guard = (__bridge DisplayGuard *)context;
    dispatch_async(dispatch_get_main_queue(), ^{ [guard check]; });
}

static int watch(BOOL dryRun, BOOL once) {
    if (once) {
        NSString *error = nil;
        NSArray *rows = discover(&error);
        if (!rows) { fail(error); return 1; }
        int lid = lidState();
        NSString *reason = nil;
        GuardState state = newGuardState();
        ReconnectMemory *memory = loadReconnectMemory();
        importManualIntent(memory);
        NSString *restoreReason = nil;
        [memory observe:rows lid:lid now:NSProcessInfo.processInfo.systemUptime reason:&restoreReason];
        recoveryPlan(rows, lid, NSProcessInfo.processInfo.systemUptime, &state, &reason);
        NSDictionary *report = @{@"mode": @"read-only", @"lid": lid < 0 ? @"unknown" : lid ? @"closed" : @"open",
                                 @"decision": restoreReason ?: reason, @"displays": rows,
                                 @"builtinPreferences": [memory.preferences copy],
                                 @"pendingReconnect": @(memory.pendingReconnect)};
        NSData *data = [NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted error:nil];
        fwrite(data.bytes, 1, data.length, stdout); putchar('\n');
        return 0;
    }
    // One active watcher per account, even if launched manually and by launchd.
    int lock = -1;
    if (!dryRun) {
        NSString *directory = [cachePath() stringByDeletingLastPathComponent];
        NSError *failure = nil;
        if (![[NSFileManager defaultManager] createDirectoryAtPath:directory withIntermediateDirectories:YES
                                                      attributes:nil error:&failure]) {
            fail(failure.localizedDescription); return 1;
        }
        lock = open([[directory stringByAppendingPathComponent:@"guard.lock"] fileSystemRepresentation],
                    O_CREAT | O_RDWR | O_CLOEXEC, 0600);
        if (lock < 0 || flock(lock, LOCK_EX | LOCK_NB) != 0) {
            fail(localize(@"监控已在运行，或无法取得监控锁。", @"The monitor is already running, or its lock could not be acquired."));
            if (lock >= 0) close(lock);
            return 1;
        }
    }
    DisplayGuard *guard = [DisplayGuard new];
    guard.dryRun = dryRun;
    CGError registered = CGDisplayRegisterReconfigurationCallback(displayChanged, (__bridge void *)guard);
    if (registered != kCGErrorSuccess)
        guardLog(localize(@"无法注册显示变化事件，将使用周期状态检查。", @"Unable to register display events. Periodic checks will be used."));
    IONotificationPortRef notifications = IONotificationPortCreate(kIOMainPortDefault);
    io_service_t root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"));
    io_object_t notifier = 0;
    if (notifications && root) {
        IONotificationPortSetDispatchQueue(notifications, dispatch_get_main_queue());
        kern_return_t result = IOServiceAddInterestNotification(notifications, root, kIOGeneralInterest,
                                    powerChanged, (__bridge void *)guard, &notifier);
        if (result != KERN_SUCCESS) guardLog(localize(@"无法注册开盖事件，将使用周期状态检查。", @"Unable to register lid events. Periodic checks will be used."));
    }
    if (root) IOObjectRelease(root);
    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC),
                              5 * NSEC_PER_SEC, 200 * NSEC_PER_MSEC);
    dispatch_source_set_event_handler(timer, ^{ [guard check]; });
    dispatch_resume(timer);
    // Ignore default termination and let the main queue clean up registered resources.
    signal(SIGTERM, SIG_IGN);
    signal(SIGINT, SIG_IGN);
    for (NSNumber *number in @[@(SIGTERM), @(SIGINT)]) {
        dispatch_source_t source = dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL,
                                      number.unsignedLongValue, 0, dispatch_get_main_queue());
        dispatch_source_set_event_handler(source, ^{
            CGDisplayRemoveReconfigurationCallback(displayChanged, (__bridge void *)guard);
            if (notifier) IOObjectRelease(notifier);
            if (notifications) IONotificationPortDestroy(notifications);
            if (lock >= 0) close(lock);
            guardLog(localize(@"监控已停止。", @"Monitor stopped."));
            exit(0);
        });
        dispatch_resume(source);
        // dispatch sources must stay alive for the lifetime of the monitor.
        static NSMutableArray *signals;
        if (!signals) signals = [NSMutableArray array];
        [signals addObject:source];
    }
    guardLog(localize(@"兜底与状态记忆监控已启动；无屏时恢复内屏，外屏接回并稳定后恢复内屏原状态。", @"Recovery and state memory monitor started. The built-in display will recover when no display is usable, and return to its previous state after a stable external reconnection."));
    [guard check];
    dispatch_main();
    return 0;
}
#endif

#ifndef DISPLAYCTL_TEST
int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc == 2 && !strcmp(argv[1], "language")) {
            puts(usesChinese() ? "zh-Hans" : "en"); return 0;
        }
        if (argc < 2 || !strcmp(argv[1], "help") || !strcmp(argv[1], "--help")) {
            usage(); return 0;
        }
        NSString *action = @(argv[1]);
        if (![@[@"list", @"on", @"off", @"toggle", @"watch", @"project"] containsObject:action]) {
            usage(); return 2;
        }
        NSString *target = nil;
        NSNumber *externalID = nil;
        BOOL dryRun = NO, json = NO, allowAllOff = NO, once = NO;
        for (int i = 2; i < argc; i++) {
            NSString *argument = @(argv[i]);
            if ([argument isEqual:@"--dry-run"]) dryRun = YES;
            else if ([argument isEqual:@"--once"]) once = YES;
            else if ([argument isEqual:@"--json"]) json = YES;
            else if ([argument isEqual:@"--allow-all-off"]) allowAllOff = YES;
            else if (!target && ![argument hasPrefix:@"-"]) target = argument;
            else if ([action isEqual:@"project"] && !externalID && argument.longLongValue > 0 &&
                     argument.longLongValue <= UINT32_MAX &&
                     [argument rangeOfCharacterFromSet:NSCharacterSet.decimalDigitCharacterSet.invertedSet].location == NSNotFound)
                externalID = @(argument.longLongValue);
            else { fail(localize(@"无法识别的参数。运行 --help 查看用法。", @"Unrecognized argument. Run --help for usage.")); return 2; }
        }
        BOOL isWatch = [action isEqual:@"watch"];
        if ((isWatch && (target || json || allowAllOff || (once && !dryRun))) ||
            (!isWatch && once) ||
            ([action isEqual:@"list"] && (target || dryRun || allowAllOff)) ||
            (!isWatch && ![action isEqual:@"list"] && (!target || json))) {
            usage(); return 2;
        }
        void *sky = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",
                           RTLD_LAZY | RTLD_LOCAL);
        if (!sky) { fail(localize(@"无法加载 macOS 显示管理接口。", @"Unable to load the macOS display management APIs.")); return 1; }
        getDisplayList = (DisplayListFn)dlsym(sky, "CGSGetDisplayList");
        configureEnabled = (DisplayEnabledFn)dlsym(sky, "CGSConfigureDisplayEnabled");
        copyDisplayInfo = (DisplayInfoFn)dlsym(sky, "SLSCopyDisplayInfoDictionary");
        createDisplayUUID = (DisplayUUIDFn)dlsym(RTLD_DEFAULT, "CGDisplayCreateUUIDFromDisplayID");
        if (!getDisplayList || !configureEnabled) {
            fail(localize(@"此版本 macOS 未提供需要的显示器启停接口。", @"This macOS version does not provide the required display enable/disable APIs.")); return 1;
        }
        if (isWatch) return watch(dryRun, once);
        NSString *error = nil;
        NSArray *rows = discover(&error);
        if (!rows) { fail(error); return 1; }
        if ([action isEqual:@"list"]) {
            if (json) {
                NSData *data = [NSJSONSerialization dataWithJSONObject:rows
                                                             options:NSJSONWritingPrettyPrinted error:nil];
                fwrite(data.bytes, 1, data.length, stdout); putchar('\n');
            } else printRows(rows);
            return 0;
        }
        if ([action isEqual:@"project"]) {
            if (allowAllOff) { usage(); return 2; }
            return project(rows, target, externalID, dryRun);
        }
        int commandLock = -1;
        if (!dryRun) {
            commandLock = operationLock(YES, &error);
            if (commandLock < 0) { fail(error); return 1; }
        }
        @try {
            if (!dryRun) {
                rows = discover(&error);
                if (!rows) { fail(error); return 1; }
            }
            NSArray *changes = plan(rows, action, target, allowAllOff, &error);
            if (!changes) { fail(error); return 2; }
            if (changes.count == 0) {
                if (!dryRun) recordBuiltinIntent(rows, action, target);
                puts(localize(@"目标已经处于所需状态。", @"The target is already in the requested state.").UTF8String); return 0;
            }
            for (NSDictionary *change in changes) {
                printf("%s %s (ID %u)%s\n", [change[@"enabled"] boolValue] ? localize(@"启用", @"Enable").UTF8String : localize(@"停用", @"Disable").UTF8String,
                       [change[@"display"][@"name"] UTF8String],
                       [change[@"display"][@"id"] unsignedIntValue], dryRun ? localize(@" [仅预览]", @" [Preview only]").UTF8String : "");
            }
            if (dryRun) return 0;
            // Save identities before a display disappears from live enumeration.
            if (!saveRemembered(rows, &error)) { fail(error); return 1; }
            if (!apply(changes, &error)) { fail(error); return 1; }
            recordBuiltinIntent(rows, action, target);
            // Wait for a bounded period and report the observed final state.
            for (int i = 0; i < 20; i++) {
                BOOL matches = YES;
                for (NSDictionary *change in changes) {
                    uint32_t identifier = [change[@"display"][@"id"] unsignedIntValue];
                    BOOL enabled = CGDisplayIsOnline(identifier) &&
                        (CGDisplayIsActive(identifier) || CGDisplayIsInMirrorSet(identifier) ||
                         CGDisplayIsInHWMirrorSet(identifier));
                    if (enabled != [change[@"enabled"] boolValue]) matches = NO;
                }
                if (matches) { puts(localize(@"完成，已核对系统显示状态。", @"Done. System display state verified.").UTF8String); return 0; }
                usleep(100000);
            }
            fail(localize(@"配置已提交，但 2 秒内系统状态未达到预期。运行 list 检查；恢复命令：on all。", @"Configuration committed, but the expected state was not observed within 2 seconds. Run list to check; recovery command: on all."));
            return 3;
        } @finally { if (commandLock >= 0) close(commandLock); }
    }
}
#else
static NSDictionary *fixture(uint32_t identifier, BOOL builtin, BOOL enabled, BOOL virtual) {
    return @{@"id": @(identifier), @"builtin": @(builtin), @"enabled": @(enabled),
             @"virtual": @(virtual), @"remembered": @NO, @"exclusive": @NO};
}
static void reconnectAssert(BOOL condition, NSString *message, unsigned *count) {
    NSCAssert(condition, @"%@", message);
    (*count)++;
}
int main(void) {
    @autoreleasepool {
        NSString *error = nil;
        NSArray *dual = @[fixture(1, YES, YES, NO), fixture(2, NO, YES, NO)];
        NSCAssert(plan(dual, @"off", @"builtin", NO, &error).count == 1, @"disable built-in with external");
        NSCAssert(plan(dual, @"off", @"external", NO, &error).count == 1, @"disable external with built-in");
        NSCAssert(plan(dual, @"off", @"all", NO, &error) == nil, @"refuse all off");
        NSCAssert(plan(dual, @"toggle", @"all", NO, &error) == nil, @"refuse all toggle off");
        NSCAssert(plan(dual, @"off", @"all", YES, &error).count == 2, @"explicit override");
        NSCAssert(plan(@[fixture(1, YES, YES, NO)], @"off", @"1", NO, &error) == nil, @"last display");
        NSCAssert(plan(@[fixture(1, YES, YES, NO), fixture(2, NO, YES, YES)], @"off", @"builtin", NO, &error) == nil, @"virtual not a fallback");
        NSCAssert(plan(dual, @"on", @"builtin", NO, &error).count == 0, @"idempotent enable");
        NSCAssert(plan(dual, @"off", @"999", NO, &error) == nil, @"unknown ID");
        NSCAssert(plan(dual, @"off", @"2garbage", NO, &error) == nil, @"reject malformed ID");
        NSCAssert(plan(dual, @"off", @"4294967296", NO, &error) == nil, @"reject overflow");
        NSArray *mixed = @[fixture(1, YES, YES, NO), fixture(2, NO, NO, NO)];
        NSCAssert(plan(mixed, @"toggle", @"all", NO, &error) == nil, @"pending enable is not a fallback");
        NSMutableDictionary *cached = [fixture(2, NO, NO, NO) mutableCopy];
        cached[@"remembered"] = @YES;
        NSCAssert(plan(@[fixture(1, YES, YES, NO), cached], @"toggle", @"all", NO, &error) == nil, @"cached screen not a fallback");
        NSCAssert(plan(@[cached], @"on", @"all", NO, &error).count == 1, @"cached recovery");
        NSMutableDictionary *exclusive = [fixture(3, NO, YES, YES) mutableCopy];
        exclusive[@"exclusive"] = @YES;
        NSCAssert(plan(@[exclusive, fixture(1, YES, NO, NO)], @"on", @"builtin", NO, &error) == nil, @"exclusive virtual guard");
        // Time-controlled unplug/lid/replug scenarios; no hardware APIs involved.
        GuardState state = newGuardState();
        NSString *reason = nil;
        NSArray *disabled = @[fixture(1, YES, NO, NO)];
        NSCAssert(recoveryPlan(dual, 0, 100, &state, &reason).count == 0, @"external prevents recovery");
        NSCAssert(recoveryPlan(disabled, 0, 101, &state, &reason).count == 0, @"unplug grace period");
        NSCAssert(recoveryPlan(disabled, 0, 101.5, &state, &reason).count == 0, @"wait one full second");
        NSArray *recovery = recoveryPlan(disabled, 0, 102, &state, &reason);
        NSCAssert(recovery.count == 1 && [recovery[0][@"enabled"] boolValue] &&
                  [recovery[0][@"display"][@"builtin"] boolValue], @"recover only builtin");
        recoveryAttempted(&state, 102);
        NSCAssert(recoveryPlan(disabled, 0, 103, &state, &reason).count == 0, @"retry throttled");
        NSCAssert(recoveryPlan(@[fixture(1, YES, YES, NO)], 0, 104, &state, &reason).count == 0, @"already restored");
        NSCAssert(recoveryPlan(dual, 0, 105, &state, &reason).count == 0, @"replug never turns builtin off");
        NSCAssert(state.attempts == 0 && state.nextAttempt == 0, @"new external resets retry incident");
        NSCAssert(recoveryPlan(disabled, 1, 106, &state, &reason).count == 0, @"closed lid");
        NSCAssert(recoveryPlan(disabled, -1, 107, &state, &reason).count == 0, @"unknown lid");
        NSCAssert(recoveryPlan(disabled, 0, 108, &state, &reason).count == 0, @"opening starts grace");
        NSCAssert(recoveryPlan(disabled, 0, 109, &state, &reason).count == 1, @"opening restores after grace");
        NSCAssert(recoveryPlan(disabled, 0, 140, &state, &reason).count == 0, @"wake starts fresh grace");
        NSCAssert(recoveryPlan(@[cached], 0, 141, &state, &reason).count == 0, @"no builtin target");
        NSCAssert(recoveryPlan(@[exclusive, fixture(1, YES, NO, NO)], 0, 142, &state, &reason).count == 0, @"exclusive mode blocks recovery");
        state = newGuardState();
        NSArray *virtualOnly = @[fixture(1, YES, NO, NO), fixture(2, NO, YES, YES)];
        recoveryPlan(virtualOnly, 0, 200, &state, &reason);
        NSCAssert(recoveryPlan(virtualOnly, 0, 201, &state, &reason).count == 1, @"virtual is not usable fallback");
        recoveryAttempted(&state, 201);
        recoveryAttempted(&state, 211);
        recoveryAttempted(&state, 221);
        NSCAssert(state.nextAttempt == 281, @"third attempt has sixty-second cooldown");
        NSMutableDictionary *knownBuiltin = [fixture(1, YES, NO, NO) mutableCopy];
        knownBuiltin[@"remembered"] = @YES;
        state = newGuardState();
        recoveryPlan(@[knownBuiltin], 0, 300, &state, &reason);
        NSCAssert(recoveryPlan(@[knownBuiltin], 0, 301, &state, &reason).count == 1, @"cached builtin can recover");
        unsigned reconnectChecks = 0;
        ReconnectMemory *memory = [ReconnectMemory new];
        NSArray *externalOnly = @[fixture(1, YES, NO, NO), fixture(2, NO, YES, NO)];
        [memory observe:externalOnly lid:0 now:400 reason:&reason];
        reconnectAssert([memory.preferences[@"id:1"] isEqual:@NO], @"learn off with external", &reconnectChecks);
        [memory observe:disabled lid:0 now:401 reason:&reason];
        reconnectAssert(memory.pendingReconnect, @"unplug starts preference episode", &reconnectChecks);
        [memory observe:@[fixture(1, YES, YES, NO)] lid:0 now:402 reason:&reason];
        reconnectAssert([memory.preferences[@"id:1"] isEqual:@NO], @"fallback does not overwrite off", &reconnectChecks);
        reconnectAssert([memory observe:dual lid:0 now:403 reason:&reason].count == 0,
                        @"replug waits for external", &reconnectChecks);
        reconnectAssert([memory observe:dual lid:0 now:404 reason:&reason].count == 0,
                        @"one second is not stable enough", &reconnectChecks);
        NSArray *restore = [memory observe:dual lid:0 now:405 reason:&reason];
        reconnectAssert(restore.count == 1 && ![restore[0][@"enabled"] boolValue] &&
                        [restore[0][@"display"][@"builtin"] boolValue], @"off restores only builtin off", &reconnectChecks);
        reconnectAssert(memory.pendingReconnect, @"submission does not complete restore", &reconnectChecks);
        [memory observe:externalOnly lid:0 now:406 reason:&reason];
        reconnectAssert(!memory.pendingReconnect && [memory.preferences[@"id:1"] isEqual:@NO],
                        @"observed off completes episode", &reconnectChecks);
        memory = [ReconnectMemory new];
        [memory observe:dual lid:0 now:500 reason:&reason];
        [memory observe:@[fixture(1, YES, YES, NO)] lid:0 now:501 reason:&reason];
        [memory observe:dual lid:0 now:502 reason:&reason];
        reconnectAssert([memory observe:dual lid:0 now:504 reason:&reason].count == 0 &&
                        [memory.preferences[@"id:1"] isEqual:@YES], @"previous on stays on", &reconnectChecks);
        [memory observe:externalOnly lid:1 now:505 reason:&reason];
        reconnectAssert([memory.preferences[@"id:1"] isEqual:@YES], @"clamshell state not learned as off", &reconnectChecks);
        [memory observe:externalOnly lid:0 now:506 reason:&reason];
        reconnectAssert([memory.preferences[@"id:1"] isEqual:@NO], @"manual off with open lid updates preference", &reconnectChecks);
        [memory observe:disabled lid:0 now:507 reason:&reason];
        [memory acceptManualIntents:@{@"id:1": @{@"enabled": @YES, @"token": @"manual-on"}}];
        [memory observe:dual lid:0 now:508 reason:&reason];
        reconnectAssert([memory observe:dual lid:0 now:510 reason:&reason].count == 0 &&
                        [memory.preferences[@"id:1"] isEqual:@YES], @"manual on during fallback overrides off", &reconnectChecks);
        [memory acceptManualIntents:@{@"id:1": @{@"enabled": @NO, @"token": @"manual-off"}}];
        [memory observe:dual lid:0 now:511 reason:&reason];
        reconnectAssert([memory.preferences[@"id:1"] isEqual:@NO], @"stale observed on cannot overwrite new manual off", &reconnectChecks);
        [memory observe:externalOnly lid:0 now:512 reason:&reason];
        reconnectAssert(![memory.manualPendingKeys containsObject:@"id:1"], @"manual intent acknowledged by observed state", &reconnectChecks);
        [memory acceptManualIntents:@{@"id:1": @{@"enabled": @NO, @"token": @"manual-off"}}];
        reconnectAssert(![memory.manualPendingKeys containsObject:@"id:1"], @"same token is not replayed", &reconnectChecks);
        [memory observe:disabled lid:0 now:513 reason:&reason];
        ReconnectMemory *reloaded = memoryFromSnapshot(reconnectSnapshot(memory));
        reconnectAssert(reloaded.pendingReconnect && [reloaded.preferences[@"id:1"] isEqual:@NO],
                        @"restart retains pending original state", &reconnectChecks);
        [reloaded observe:dual lid:0 now:514 reason:&reason];
        reconnectAssert([reloaded observe:dual lid:0 now:516 reason:&reason].count == 1,
                        @"restart can finish restore", &reconnectChecks);
        reconnectAssert([reloaded observe:dual lid:1 now:517 reason:&reason].count == 0,
                        @"closed lid defers restoration", &reconnectChecks);
        reconnectAssert([reloaded observe:dual lid:-1 now:518 reason:&reason].count == 0,
                        @"unknown lid defers restoration", &reconnectChecks);
        reconnectAssert([reloaded observe:dual lid:0 now:519 reason:&reason].count == 1,
                        @"opened lid allows restoration", &reconnectChecks);
        reconnectAssert([reloaded observe:@[fixture(1, YES, YES, NO)] lid:0 now:520 reason:&reason].count == 0,
                        @"external loss cancels off plan", &reconnectChecks);
        [reloaded observe:dual lid:0 now:521 reason:&reason];
        reconnectAssert([reloaded observe:dual lid:0 now:522 reason:&reason].count == 0,
                        @"bounce restarts stability wait", &reconnectChecks);
        [reloaded observe:@[fixture(1, YES, YES, NO), fixture(2, NO, YES, YES)] lid:0 now:523 reason:&reason];
        reconnectAssert(!reloaded.externalWasAvailable, @"virtual display is not a replug fallback", &reconnectChecks);
        NSMutableDictionary *firstID = [fixture(1, YES, NO, NO) mutableCopy]; firstID[@"uuid"] = @"internal-uuid";
        NSMutableDictionary *newID = [fixture(7, YES, YES, NO) mutableCopy]; newID[@"uuid"] = @"internal-uuid";
        memory = [ReconnectMemory new];
        [memory observe:@[firstID, fixture(2, NO, YES, NO)] lid:0 now:600 reason:&reason];
        [memory observe:@[firstID] lid:0 now:601 reason:&reason];
        [memory observe:@[newID, fixture(3, NO, YES, NO)] lid:0 now:602 reason:&reason];
        restore = [memory observe:@[newID, fixture(3, NO, YES, NO)] lid:0 now:604 reason:&reason];
        reconnectAssert(restore.count == 1 && [restore[0][@"display"][@"id"] unsignedIntValue] == 7,
                        @"UUID survives display ID changes", &reconnectChecks);
        reconnectAssert([memory observe:@[fixture(3, NO, YES, NO)] lid:0 now:605 reason:&reason].count == 0 &&
                        memory.pendingReconnect, @"missing builtin does not discard stored preference", &reconnectChecks);
        unsigned projectionChecks = 0;
        reconnectAssert(projectionPlan(dual, @"internal", nil, &error) != nil, @"internal projection", &projectionChecks);
        reconnectAssert(projectionPlan(dual, @"external", @2, &error) != nil, @"external projection", &projectionChecks);
        reconnectAssert(projectionPlan(dual, @"duplicate", nil, &error) != nil, @"duplicate projection", &projectionChecks);
        reconnectAssert(projectionPlan(dual, @"extend", nil, &error) != nil, @"extended projection", &projectionChecks);
        reconnectAssert(projectionPlan(disabled, @"external", nil, &error) == nil, @"no external refused", &projectionChecks);
        reconnectAssert(projectionPlan(disabled, @"internal", nil, &error) != nil, @"internal without external", &projectionChecks);
        reconnectAssert(projectionPlan(@[fixture(2, NO, YES, NO)], @"extend", nil, &error) == nil, @"desktop refused", &projectionChecks);
        reconnectAssert(projectionPlan(dual, @"invalid", nil, &error) == nil, @"invalid mode", &projectionChecks);
        reconnectAssert(projectionPlan(dual, @"duplicate", @999, &error) == nil, @"invalid external ID", &projectionChecks);
        reconnectAssert(projectionPlan(virtualOnly, @"duplicate", nil, &error) == nil, @"virtual not second screen", &projectionChecks);
        reconnectAssert(projectionPlan(@[exclusive, fixture(1, YES, NO, NO)], @"internal", nil, &error) == nil, @"exclusive mode refused", &projectionChecks);
        NSDictionary *chosen = projectionPlan(@[fixture(1, YES, YES, NO), cached, fixture(3, NO, YES, NO)], @"extend", nil, &error);
        reconnectAssert([chosen[@"external"][@"id"] isEqual:@3], @"prefer live external", &projectionChecks);
        unsigned connectionChecks = 0;
        NSMutableData *edid = [NSMutableData dataWithLength:128];
        uint8_t *bytes = edid.mutableBytes;
        const uint8_t prefix[] = {0, 255, 255, 255, 255, 255, 255, 0};
        memcpy(bytes, prefix, sizeof(prefix));
        bytes[8] = 0x12; bytes[9] = 0x34; bytes[10] = 0x78; bytes[11] = 0x56;
        bytes[12] = 4; bytes[13] = 3; bytes[14] = 2; bytes[15] = 1;
        NSString *monitor = monitorIdentity(0x1234, 0x5678, 0x01020304);
        reconnectAssert([edidIdentity(edid) isEqual:monitor], @"EDID identity matches CoreGraphics vendor/product/serial", &connectionChecks);
        reconnectAssert(edidIdentity([NSData data]) == nil && edidIdentity(@"invalid") == nil,
                        @"invalid EDID ignored", &connectionChecks);
        reconnectAssert(portMonitorIdentity(@{@"EDID": edid, @"HPD_StateDescription": @"Low"}) == nil,
                        @"stale EDID on disconnected port ignored", &connectionChecks);
        reconnectAssert([portMonitorIdentity(@{@"EDID": edid, @"HPD_StateDescription": @"High"}) isEqual:monitor],
                        @"connected Apple port detected", &connectionChecks);
        reconnectAssert([portMonitorIdentity(@{@"IODisplayEDID": edid}) isEqual:monitor],
                        @"Intel display EDID detected", &connectionChecks);
        NSMutableDictionary *physical = [cached mutableCopy];
        physical[@"vendor"] = @0x1234; physical[@"product"] = @0x5678; physical[@"serial"] = @0x01020304;
        physical[@"online"] = @NO;
        reconnectAssert([connectionState(physical, [NSSet setWithObject:monitor]) isEqual:@YES],
                        @"soft-disabled cached screen remains physically connected", &connectionChecks);
        reconnectAssert([connectionState(physical, NSSet.set) isEqual:@NO], @"unplugged cached screen detected", &connectionChecks);
        reconnectAssert([connectionState(physical, [NSSet setWithObject:@"other-monitor"]) isEqual:@NO],
                        @"different connected monitor cannot enable cached target", &connectionChecks);
        reconnectAssert(connectionState(physical, nil) == NSNull.null, @"failed probe stays unknown", &connectionChecks);
        physical[@"connected"] = @NO;
        reconnectAssert(projectionPlan(@[fixture(1, YES, YES, NO), physical], @"duplicate", @2, &error) == nil,
                        @"disconnected external rejected before display transaction", &connectionChecks);
        reconnectAssert(projectionPlan(@[fixture(1, YES, YES, NO), physical], @"internal", nil, &error) != nil,
                        @"built-in only allowed without external connection", &connectionChecks);
        physical[@"connected"] = @YES;
        reconnectAssert(projectionPlan(@[fixture(1, YES, YES, NO), physical], @"extend", @2, &error) != nil,
                        @"connected soft-disabled screen can be enabled", &connectionChecks);
        unsigned layoutChecks = 0;
        NSDictionary *(^positioned)(uint32_t, BOOL, int, int, BOOL) = ^NSDictionary *(uint32_t identifier, BOOL builtin, int x, int y, BOOL main) {
            NSMutableDictionary *row = [fixture(identifier, builtin, YES, NO) mutableCopy];
            row[@"uuid"] = builtin ? @"builtin-uuid" : @"external-uuid";
            row[@"x"] = @(x); row[@"y"] = @(y); row[@"main"] = @(main);
            return row;
        };
        NSDictionary *bottom = positioned(1, YES, 0, 0, YES);
        NSDictionary *top = positioned(2, NO, -160, -1440, NO);
        NSArray *vertical = @[bottom, top];
        NSDictionary *layouts = updatedLayouts(@{}, vertical, @"boot-a");
        NSDictionary *verticalPlan = projectionPlan(vertical, @"extend", nil, &error);
        NSDictionary *verticalLayout = savedLayout(layouts, verticalPlan, @"boot-a");
        reconnectAssert([verticalLayout[@"external"][@"x"] isEqual:@(-160)] &&
                        [verticalLayout[@"external"][@"y"] isEqual:@(-1440)], @"vertical arrangement and offset retained", &layoutChecks);
        NSData *layoutJSON = [NSJSONSerialization dataWithJSONObject:layouts options:0 error:nil];
        layouts = [NSJSONSerialization JSONObjectWithData:layoutJSON options:0 error:nil];
        reconnectAssert([savedLayout(layouts, verticalPlan, @"boot-a") isEqual:verticalLayout], @"layout survives process JSON round trip", &layoutChecks);
        NSMutableDictionary *mirroredTop = [top mutableCopy];
        mirroredTop[@"mirror"] = @YES; mirroredTop[@"mirrorOf"] = @1;
        mirroredTop[@"x"] = @0; mirroredTop[@"y"] = @0;
        reconnectAssert([updatedLayouts(layouts, @[bottom, mirroredTop], @"boot-a") isEqual:layouts], @"mirror does not overwrite extended arrangement", &layoutChecks);
        NSMutableDictionary *offTop = [top mutableCopy]; offTop[@"enabled"] = @NO;
        reconnectAssert([updatedLayouts(layouts, @[bottom, offTop], @"boot-a") isEqual:layouts], @"built-in only preserves arrangement", &layoutChecks);
        NSMutableDictionary *offBottom = [bottom mutableCopy]; offBottom[@"enabled"] = @NO;
        reconnectAssert([updatedLayouts(layouts, @[offBottom, top], @"boot-a") isEqual:layouts], @"external only preserves arrangement", &layoutChecks);
        NSMutableDictionary *unplugged = [top mutableCopy]; unplugged[@"remembered"] = @YES;
        reconnectAssert([updatedLayouts(layouts, @[bottom, unplugged], @"boot-a") isEqual:layouts], @"unplugged cache does not overwrite arrangement", &layoutChecks);
        NSMutableDictionary *virtualTop = [top mutableCopy]; virtualTop[@"virtual"] = @YES;
        reconnectAssert([updatedLayouts(layouts, @[bottom, virtualTop], @"boot-a") isEqual:layouts], @"virtual displays do not alter physical arrangement", &layoutChecks);
        reconnectAssert([updatedLayouts(layouts, @[bottom, positioned(2, NO, 0, 0, NO)], @"boot-a") isEqual:layouts], @"coincident origins do not overwrite arrangement", &layoutChecks);
        NSArray *newIDs = @[positioned(8, YES, 0, 0, YES), positioned(9, NO, 0, 900, NO)];
        NSDictionary *newPlan = projectionPlan(newIDs, @"extend", nil, &error);
        reconnectAssert([savedLayout(layouts, newPlan, @"boot-b") isEqual:verticalLayout], @"UUID restores after reboot and display ID change", &layoutChecks);
        NSMutableDictionary *differentExternal = [newIDs[1] mutableCopy]; differentExternal[@"uuid"] = @"another-external";
        NSDictionary *differentPlan = projectionPlan(@[newIDs[0], differentExternal], @"extend", nil, &error);
        reconnectAssert(savedLayout(layouts, differentPlan, @"boot-b") == nil, @"different monitor never inherits arrangement", &layoutChecks);
        NSDictionary *belowLayout = savedLayout(updatedLayouts(layouts, newIDs, @"boot-b"), newPlan, @"boot-b");
        reconnectAssert([belowLayout[@"external"][@"y"] isEqual:@900], @"manual rearrangement replaces saved arrangement", &layoutChecks);
        NSDictionary *leftMain = captureLayout(positioned(1, YES, 1920, -200, NO), positioned(2, NO, 0, 0, YES));
        reconnectAssert([leftMain[@"builtin"][@"x"] isEqual:@1920] &&
                        [leftMain[@"builtin"][@"y"] isEqual:@(-200)] &&
                        [leftMain[@"external"][@"x"] isEqual:@0], @"external main display and negative offset retained", &layoutChecks);
        NSDictionary *leftLayout = captureLayout(bottom, positioned(2, NO, -1920, 100, NO));
        reconnectAssert([leftLayout[@"external"][@"x"] isEqual:@(-1920)], @"left arrangement retained", &layoutChecks);
        NSMutableDictionary *noUUIDBottom = [bottom mutableCopy], *noUUIDTop = [top mutableCopy];
        [noUUIDBottom removeObjectForKey:@"uuid"]; [noUUIDTop removeObjectForKey:@"uuid"];
        NSDictionary *idLayouts = updatedLayouts(@{}, @[noUUIDBottom, noUUIDTop], @"boot-a");
        NSDictionary *idPlan = projectionPlan(@[noUUIDBottom, noUUIDTop], @"extend", nil, &error);
        reconnectAssert(savedLayout(idLayouts, idPlan, @"boot-a") != nil, @"ID fallback works within boot", &layoutChecks);
        reconnectAssert(savedLayout(idLayouts, idPlan, @"boot-b") == nil, @"ID fallback cannot select another monitor after reboot", &layoutChecks);
        NSString *key = layoutKey(bottom, top, @"boot-a");
        reconnectAssert(savedLayout(@{key: @"broken"}, verticalPlan, @"boot-a") == nil, @"corrupt layout ignored", &layoutChecks);
        reconnectAssert(!validOrigin(@{@"x": @(INFINITY), @"y": @0}) &&
                        !validOrigin(@{@"x": @0.5, @"y": @0}) &&
                        !validOrigin(@{@"x": @((int64_t)INT32_MAX + 1), @"y": @0}), @"invalid coordinates rejected", &layoutChecks);
        NSDictionary *targets = projectionOrigins(@{@"mode": @"extend", @"layout": verticalLayout}, 1512);
        reconnectAssert([targets[@"external"][@"x"] isEqual:@(-160)] &&
                        [targets[@"external"][@"y"] isEqual:@(-1440)], @"extended transaction uses stored vertical coordinates", &layoutChecks);
        targets = projectionOrigins(@{@"mode": @"extend", @"layout": leftMain}, 1512);
        reconnectAssert([targets[@"builtin"][@"x"] isEqual:@1920] &&
                        [targets[@"external"][@"x"] isEqual:@0], @"extended transaction restores external main display", &layoutChecks);
        for (NSString *singleMode in @[@"internal", @"external", @"duplicate"]) {
            targets = projectionOrigins(@{@"mode": singleMode, @"layout": verticalLayout}, 1512);
            reconnectAssert([targets[@"builtin"] isEqual:@{@"x": @0, @"y": @0}] &&
                            [targets[@"external"] isEqual:@{@"x": @0, @"y": @0}], @"single and mirror modes do not use extended origins", &layoutChecks);
        }
        targets = projectionOrigins(@{@"mode": @"extend"}, 1512);
        reconnectAssert([targets[@"external"][@"x"] isEqual:@1512] &&
                        [targets[@"external"][@"y"] isEqual:@0], @"no-history fallback uses logical display width", &layoutChecks);
        printf("15 command planning checks, 18 guard policy checks, and %u reconnect checks passed; no hardware toggled.\n", reconnectChecks);
        printf("%u projection planning checks passed.\n", projectionChecks);
        printf("%u display arrangement memory checks passed.\n", layoutChecks);
        printf("%u physical connection checks passed.\n", connectionChecks);
        return 0;
    }
}
#endif
