//
//  LSStoreParser.m
//  Qingsao
//
//  CSStore2 ("bdsl") parser ported from WQFiles by kolbicz
//  (GPL-3.0-or-later): record layouts, string-table decoding, container
//  claiming and AppGroup path extraction follow the original. The
//  layout-vote diagnostics of the original are reduced to a summary line.
//

#import "LSStoreParser.h"
#include <stdlib.h>
#include <string.h>

static const size_t kLSMinStoreBytes = 0x1000;
static const size_t kLSMaxStoreBytes = 64u * 1024u * 1024u;
static const uint32_t kLSMaxStringID = 0x01000000u;
static const NSUInteger kLSMaxBundleRecords = 100000;
static const NSUInteger kLSMaxDecodedStrings = 200000;
static const NSUInteger kLSMaxDecodedStringBytes = 8u * 1024u * 1024u;
static const size_t kLSMaxRecordSize = 0x25c;

// Record layouts by release. Offsets are from the record body (after the
// 8-byte header).
typedef struct {
    const char *label;
    uint32_t bundleSize, bundleID, container, name, displayName, bundlePath;
    uint32_t pluginSize, pluginBundleID, pluginContainer;
} LSLayout;

static const LSLayout kLSLayouts[] = {
    { "27.0", 0x250, 0x0c, 0x68, 0x6c, 0x74, 0x00, 0x118, 0x00, 0x54 },
    { "26",   0x23c, 0x0c, 0x64, 0x68, 0x70, 0x00, 0x104, 0x00, 0x50 },
    // iOS 27.2: container fields 4 bytes later than on 27.0; whether the
    // bundle id moved too is unknown, so both positions are tried and the
    // layout that maps the most containers wins.
    { "27.2",  0x25c, 0x0c, 0x6c, 0x70, 0x78, 0x00, 0x120, 0x00, 0x58 },
    { "27.2b", 0x25c, 0x10, 0x6c, 0x70, 0x78, 0x00, 0x120, 0x04, 0x58 },
    { "27.2c", 0x25c, 0x0c, 0x6c, 0x70, 0x78, 0x00, 0x120, 0x04, 0x58 },
    { "27.2d", 0x25c, 0x10, 0x6c, 0x70, 0x78, 0x00, 0x120, 0x00, 0x58 },
};
static const size_t kLSLayoutCount = sizeof(kLSLayouts) / sizeof(kLSLayouts[0]);

static uint32_t ls_rd32(const uint8_t *p) { uint32_t v; memcpy(&v, p, 4); return v; }

static NSString *ls_cs_string(const uint8_t *b, size_t n, size_t o)
{
    if (o > n || n - o < 8) return nil;
    uint32_t len = ls_rd32(b + o + 4);
    // Strings are padded with zero bytes to a multiple of 4. One whose
    // length is already a multiple of 4 has no terminator (container paths
    // are 84 or 88 bytes), so only shorter ones must end in a zero byte.
    if (len == 0 || len >= 0x800 || len >= n - o - 8 || (len % 4 && b[o + 8 + len] != 0)) return nil;
    if (memchr(b + o + 8, 0, len)) return nil;
    return [[NSString alloc] initWithBytes:b + o + 8 length:len encoding:NSUTF8StringEncoding];
}

static BOOL ls_looks_like_bundle_id(NSString *s)
{
    static NSCharacterSet *bad;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        bad = [[NSCharacterSet characterSetWithCharactersInString:
                @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_"] invertedSet];
    });
    return s.length > 2 && [s containsString:@"."] && ![s hasPrefix:@"."]
        && [s rangeOfCharacterFromSet:bad].location == NSNotFound;
}

static BOOL ls_is_name_format_scalar(uint32_t c)
{
    return c == 0x00ad || (c >= 0x0600 && c <= 0x0605) || c == 0x061c || c == 0x06dd ||
        c == 0x070f || (c >= 0x0890 && c <= 0x0891) || c == 0x08e2 || c == 0x180e ||
        (c >= 0x200b && c <= 0x200f) || (c >= 0x202a && c <= 0x202e) ||
        (c >= 0x2060 && c <= 0x206f) || c == 0xfeff;
}

static NSString *ls_safe_name(NSString *value)
{
    if (!value.length) return nil;
    NSMutableString *safe = [NSMutableString stringWithCapacity:value.length];
    for (NSUInteger i = 0; i < value.length;) {
        uint32_t scalar = [value characterAtIndex:i++];
        if (scalar >= 0xd800 && scalar <= 0xdbff) {
            if (i >= value.length) return nil;
            unichar low = [value characterAtIndex:i++];
            if (low < 0xdc00 || low > 0xdfff) return nil;
            scalar = 0x10000u + ((scalar - 0xd800u) << 10) + (low - 0xdc00u);
        } else if (scalar >= 0xdc00 && scalar <= 0xdfff) {
            return nil;
        }
        if (ls_is_name_format_scalar(scalar) || scalar == 0x2028 || scalar == 0x2029) {
            [safe appendString:@"\uFFFD"];
        } else if (scalar <= 0xffff) {
            [safe appendFormat:@"%C", (unichar)scalar];
        } else {
            scalar -= 0x10000u;
            [safe appendFormat:@"%C%C", (unichar)(0xd800u + (scalar >> 10)),
             (unichar)(0xdc00u + (scalar & 0x3ffu))];
        }
    }
    NSString *normalized = [safe precomposedStringWithCanonicalMapping];
    normalized = [normalized stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!normalized.length || [normalized hasPrefix:@"/"] || [normalized containsString:@".app/"]) return nil;
    if ([normalized rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location != NSNotFound) return nil;
    return normalized;
}

static BOOL ls_is_data_container_path(NSString *path)
{
    static NSArray<NSString *> *prefixes;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        prefixes = @[@"/private/var/mobile/Containers/Data/Application/",
                     @"/private/var/mobile/Containers/Data/PluginKitPlugin/"];
    });
    for (NSString *prefix in prefixes) {
        if (![path hasPrefix:prefix] || path.length != prefix.length + 36) continue;
        return [[NSUUID alloc] initWithUUIDString:[path substringFromIndex:prefix.length]] != nil;
    }
    return NO;
}

NSDictionary<NSString *, id> *LSStoreParse(NSData *data)
{
    const uint8_t *b = data.bytes;
    size_t n = data.length;
    if (n < kLSMinStoreBytes || n > kLSMaxStoreBytes || !b || memcmp(b, "bdsl", 4) != 0) {
        return nil;
    }
    NSRange heapRange = [data rangeOfData:[NSData dataWithBytes:"<string>" length:8]
                                  options:0 range:NSMakeRange(0, n)];
    size_t heap = heapRange.location == NSNotFound ? 0 : heapRange.location;

    // Pass 1: Bundle and plug-in records of every known layout, and which
    // string ids they need. The layout that maps the most containers wins.
    const uint32_t kIDs = kLSMaxStringID;
    size_t bitsetBytes = kIDs / 8;
    uint8_t *need = calloc(bitsetBytes, 1), *inHeap = calloc(bitsetBytes, 1);
    NSMutableArray<NSMutableData *> *layoutRecs = [NSMutableArray new], *layoutPlugins = [NSMutableArray new];
    for (size_t l = 0; l < kLSLayoutCount; l++) {
        [layoutRecs addObject:[NSMutableData new]];
        [layoutPlugins addObject:[NSMutableData new]];
    }
    if (!need || !inHeap) {
        free(need);
        free(inHeap);
        return nil;
    }

    BOOL tooManyRecords = NO;
    for (size_t o = 0; o + 8 + kLSMaxRecordSize <= n && !tooManyRecords; o += 4) {
        uint32_t size = ls_rd32(b + o + 4);
        const uint8_t *u = b + o + 8;
        for (size_t l = 0; l < kLSLayoutCount; l++) {
            const LSLayout *L = &kLSLayouts[l];
            if (size == L->pluginSize) {
                NSMutableData *plugins = layoutPlugins[l];
                uint32_t p[2] = { ls_rd32(u + L->pluginBundleID), ls_rd32(u + L->pluginContainer) };
                if (p[0] && !(p[0] & 3) && (p[0] >> 2) < kIDs && p[1] && !(p[1] & 3) && (p[1] >> 2) < kIDs &&
                    plugins.length / sizeof(p) < kLSMaxBundleRecords) {
                    [plugins appendBytes:p length:sizeof(p)];
                    for (int i = 0; i < 2; i++) need[(p[i] >> 2) / 8] |= 1 << ((p[i] >> 2) % 8);
                }
            }
            if (size != L->bundleSize) continue;
            NSMutableData *recs = layoutRecs[l];
            if (recs.length / (5 * sizeof(uint32_t)) >= kLSMaxBundleRecords) {
                tooManyRecords = YES;
                break;
            }
            uint32_t r[5] = { ls_rd32(u + L->bundleID), ls_rd32(u + L->name), ls_rd32(u + L->displayName),
                              ls_rd32(u + L->container), ls_rd32(u + L->bundlePath) };
            if (!r[0] || (r[0] & 3) || (r[0] >> 2) >= kIDs) continue;
            [recs appendBytes:r length:sizeof(r)];
            for (int i = 0; i < 5; i++) {
                if (r[i] && !(r[i] & 3) && (r[i] >> 2) < kIDs)
                    need[(r[i] >> 2) / 8] |= 1 << ((r[i] >> 2) % 8);
            }
        }
    }
    if (tooManyRecords) {
        free(need);
        free(inHeap);
        return nil;
    }

    // Pass 2: the strings, preferring copies inside the string table. On
    // iOS 26 container paths live in a second table whose ids overlap the
    // string table's, so path-shaped strings are also kept by id on their
    // own (an id with two different paths is unusable).
    NSMutableDictionary<NSNumber *, NSString *> *strings = [NSMutableDictionary new];
    NSMutableDictionary<NSNumber *, id> *pathStrings = [NSMutableDictionary new];
    NSMutableDictionary<NSNumber *, id> *appPathStrings = [NSMutableDictionary new];
    NSUInteger decodedStringBytes = 0;
    BOOL tooManyStrings = NO;
    for (size_t o = 0; o <= n - 8; o += 4) {
        uint32_t sid = ls_rd32(b + o);
        if (!sid || sid >= kIDs || !(need[sid / 8] & (1 << (sid % 8)))) continue;
        BOOL here = o >= heap, had = strings[@(sid)] != nil;
        BOOL keepGeneral = !had || (here && !(inHeap[sid / 8] & (1 << (sid % 8))));
        uint32_t peekLen = o + 8 <= n ? ls_rd32(b + o + 4) : 0;
        BOOL maybePath = peekLen >= 6 && peekLen < 0x400 && o + 8 < n && b[o + 8] == '/';
        if (!keepGeneral && !maybePath) continue;
        NSString *s = ls_cs_string(b, n, o);
        if (!s) continue;
        if (maybePath) {
            NSMutableDictionary *table = [s containsString:@"/mobile/Containers/Data/"] ? pathStrings
                : ([s hasSuffix:@".app"] || [s hasSuffix:@".app/"]) ? appPathStrings : nil;
            id previous = table[@(sid)];
            if (table && !previous) table[@(sid)] = s;
            else if (table && ![previous isEqual:s]) table[@(sid)] = NSNull.null;
        }
        if (!keepGeneral) continue;
        if (!had && (strings.count >= kLSMaxDecodedStrings ||
                     s.length > kLSMaxDecodedStringBytes - decodedStringBytes)) {
            tooManyStrings = YES;
            break;
        }
        strings[@(sid)] = s;
        if (!had) decodedStringBytes += s.length;
        if (here) inHeap[sid / 8] |= 1 << (sid % 8);
    }
    free(need);
    free(inHeap);
    if (tooManyStrings) return nil;

    NSUInteger anyRecords = 0;
    for (size_t l = 0; l < kLSLayoutCount; l++) {
        anyRecords += layoutRecs[l].length / (5 * sizeof(uint32_t));
    }
    if (!anyRecords) return nil;

    NSString *(^pathFor)(uint32_t) = ^NSString *(uint32_t ref) {
        id path = pathStrings[@(ref >> 2)];
        if (path == NSNull.null) return nil;
        return path ?: strings[@(ref >> 2)];
    };
    NSDictionary *display = nil, *bundleName = nil, *containers = nil, *bundlePaths = nil;
    size_t chosen = 0;
    for (size_t l = 0; l < kLSLayoutCount; l++) {
        NSMutableDictionary *layoutDisplay = [NSMutableDictionary new], *layoutBundleName = [NSMutableDictionary new];
        NSMutableDictionary *layoutBundlePaths = [NSMutableDictionary new];
        NSMutableDictionary<NSString *, id> *layoutContainers = [NSMutableDictionary new];
        // A path claimed by two different bundle ids is left out rather
        // than guessed. Plug-in records only claim extension containers
        // and bundle records only app containers.
        void (^claim)(NSString *, NSString *, NSString *) = ^(NSString *path, NSString *bid, NSString *kind) {
            if ([path hasSuffix:@"/"]) path = [path substringToIndex:path.length - 1];
            if ([path hasPrefix:@"/var/"]) path = [@"/private" stringByAppendingString:path];
            if (!ls_is_data_container_path(path) || !ls_looks_like_bundle_id(bid) || ![path containsString:kind]) return;
            id known = layoutContainers[path];
            if (!known) layoutContainers[path] = bid;
            else if (![known isEqual:bid]) layoutContainers[path] = NSNull.null;
        };
        NSData *plugins = layoutPlugins[l], *recs = layoutRecs[l];
        const uint32_t *pr = plugins.bytes;
        for (NSUInteger i = 0; i < plugins.length / sizeof(uint32_t); i += 2)
            claim(pathFor(pr[i + 1]), strings[@(pr[i] >> 2)], @"/Data/PluginKitPlugin/");
        const uint32_t *r = recs.bytes;
        for (NSUInteger i = 0; i < recs.length / sizeof(uint32_t); i += 5) {
            NSString *bid = strings[@(r[i] >> 2)];
            if (!ls_looks_like_bundle_id(bid)) continue;
            if (r[i + 3] && !(r[i + 3] & 3)) claim(pathFor(r[i + 3]), bid, @"/Data/Application/");
            NSString *nm = (r[i + 1] & 3) ? nil : strings[@(r[i + 1] >> 2)];
            NSString *dn = (r[i + 2] & 3) ? nil : strings[@(r[i + 2] >> 2)];
            NSString *safeDisplay = ls_safe_name(dn);
            NSString *safeBundleName = ls_safe_name(nm);
            if (safeDisplay && !layoutDisplay[bid]) layoutDisplay[bid] = safeDisplay;
            if (safeBundleName && !layoutBundleName[bid]) layoutBundleName[bid] = safeBundleName;
            id appPath = (r[i + 4] && !(r[i + 4] & 3)) ? appPathStrings[@(r[i + 4] >> 2)] : nil;
            if ([appPath isKindOfClass:NSString.class] && !layoutBundlePaths[bid]) {
                NSString *clean = [appPath hasSuffix:@"/"] ? [appPath substringToIndex:[appPath length] - 1] : appPath;
                if ([clean hasPrefix:@"/var/"]) clean = [@"/private" stringByAppendingString:clean];
                layoutBundlePaths[bid] = clean;
            }
        }
        for (NSString *path in layoutContainers.allKeys)
            if (layoutContainers[path] == NSNull.null) [layoutContainers removeObjectForKey:path];
        if (!containers || layoutContainers.count > containers.count ||
            (layoutContainers.count == containers.count && layoutDisplay.count > display.count)) {
            display = layoutDisplay;
            bundleName = layoutBundleName;
            containers = layoutContainers;
            bundlePaths = layoutBundlePaths;
            chosen = l;
        }
    }
    if (!containers) return nil;

    // App group containers are not mapped to an owner in the store; the
    // store's raw bytes list the group containers of installed apps.
    NSMutableSet<NSString *> *groups = [NSMutableSet set];
    static const char needle[] = "/mobile/Containers/Shared/AppGroup/";
    const uint8_t *cursor = b, *end = b + n;
    while (cursor < end) {
        const uint8_t *hit = memmem(cursor, (size_t)(end - cursor), needle, sizeof(needle) - 1);
        if (!hit) break;
        cursor = hit + sizeof(needle) - 1;
        if ((size_t)(end - cursor) < 36) break;
        NSString *uuid = [[NSString alloc] initWithBytes:cursor length:36 encoding:NSASCIIStringEncoding];
        if (!uuid || ![[NSUUID alloc] initWithUUIDString:uuid]) continue;
        [groups addObject:[@"/private/var/mobile/Containers/Shared/AppGroup/"
                            stringByAppendingString:uuid.uppercaseString]];
    }

    NSString *summary = [NSString stringWithFormat:
        @"store %.1f MB, layout %s: %lu names, %lu containers mapped, %lu group containers",
        n / 1048576.0, kLSLayouts[chosen].label, (unsigned long)display.count,
        (unsigned long)containers.count, (unsigned long)groups.count];

    return @{
        @"display": display ?: @{},
        @"bundleName": bundleName ?: @{},
        @"containers": containers,
        @"bundlePaths": bundlePaths ?: @{},
        @"groups": groups.allObjects,
        @"summary": summary,
    };
}
