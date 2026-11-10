//
//  LSStoreParser.h
//  Qingsao
//
//  Parser for the LaunchServices CSStore2 database (com.apple.LaunchServices
//  *.csstore, magic "bdsl") that lsd keeps inside its daemon container.
//  Ported from WQFiles by kolbicz (GPL-3.0-or-later), itself built on the
//  worse_query sandbox technique by Taj C. Qingsao is GPL-3.0; see LICENSE
//  notices in the project README.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Parses one CSStore2 blob. Returns nil when the blob is not a store or
/// holds no bundle records. Keys:
///   @"display"    NSDictionary<NSString *, NSString *> bundle id -> display name
///   @"bundleName" NSDictionary<NSString *, NSString *> bundle id -> bundle name
///   @"containers" NSDictionary<NSString *, NSString *> container path -> bundle id
///   @"bundlePaths" NSDictionary<NSString *, NSString *> bundle id -> .app path
///   @"groups"     NSArray<NSString *> shared AppGroup container paths
///   @"summary"    NSString, one-line statistics for the log
NSDictionary<NSString *, id> *_Nullable LSStoreParse(NSData *data);

NS_ASSUME_NONNULL_END
