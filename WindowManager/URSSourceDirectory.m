/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "URSSourceDirectory.h"

// Applications sit at most this deep below their repository (the repository
// itself being level 0); deeper is build output or vendored code.
static const NSUInteger kMaxDepth = 5;

static NSMutableDictionary *indexes;          // root -> entry
static NSString *const kIndexKey = @"index";  // name -> array of directories
static NSString *const kBuiltKey = @"built";  // NSNumber, reference time
static NSTimeInterval rescanInterval = 5.0;
static NSUInteger walkCount = 0;

@implementation URSSourceDirectory

+ (NSString *)sourceRoot
{
  return @"/Developer/Library/Sources";
}

+ (NSTimeInterval)rescanInterval
{
  return rescanInterval;
}

+ (void)setRescanInterval:(NSTimeInterval)seconds
{
  rescanInterval = seconds;
}

+ (NSUInteger)walkCount
{
  return walkCount;
}

// Directories that never hold the source of an installed application: VCS
// data and build output, built products (their makefiles are copies), and
// hidden directories such as .claude, whose worktrees are copies of the
// repository and would make every name ambiguous.
+ (BOOL)skipsDirectoryNamed:(NSString *)name
{
  if ([name hasPrefix: @"."]) {
    return YES;
  }
  if ([name isEqualToString: @"obj"] || [name isEqualToString: @"derived_src"]
      || [name isEqualToString: @"node_modules"]) {
    return YES;
  }
  NSString *ext = [name pathExtension];
  return [ext isEqualToString: @"app"] || [ext isEqualToString: @"framework"]
    || [ext isEqualToString: @"bundle"];
}

// The names a makefile's text declares with APP_NAME (=, :=, += and ?=, any
// number per line and over continued lines).
+ (NSArray *)applicationNamesInMakefile:(NSString *)text
{
  NSMutableArray *names = [NSMutableArray array];
  NSCharacterSet *blank = [NSCharacterSet whitespaceAndNewlineCharacterSet];
  text = [text stringByReplacingOccurrencesOfString: @"\\\n" withString: @" "];

  for (NSString *rawLine in [text componentsSeparatedByString: @"\n"]) {
    NSString *line = rawLine;
    NSRange hash = [line rangeOfString: @"#"];
    if (hash.location != NSNotFound) {
      line = [line substringToIndex: hash.location];
    }
    line = [line stringByTrimmingCharactersInSet: blank];
    if (![line hasPrefix: @"APP_NAME"]) {
      continue;
    }
    // Without this, APP_NAME_FOO would count as APP_NAME.
    if ([line length] > 8 && ![blank characterIsMember: [line characterAtIndex: 8]]
        && [@":+?=" rangeOfString: [line substringWithRange: NSMakeRange(8, 1)]].location
           == NSNotFound) {
      continue;
    }
    NSString *rest = [[line substringFromIndex: 8] stringByTrimmingCharactersInSet: blank];
    if ([rest hasPrefix: @":"] || [rest hasPrefix: @"+"] || [rest hasPrefix: @"?"]) {
      rest = [rest substringFromIndex: 1];
    }
    if (![rest hasPrefix: @"="]) {
      continue;
    }
    for (NSString *word in [[rest substringFromIndex: 1]
                            componentsSeparatedByCharactersInSet: blank]) {
      // Nothing is expanded here, so a make variable is not a name.
      if ([word length] > 0 && [word rangeOfString: @"$"].location == NSNotFound) {
        [names addObject: word];
      }
    }
  }
  return names;
}

+ (void)indexDirectory:(NSString *)directory
                 depth:(NSInteger)depth
                  into:(NSMutableDictionary *)index
{
  NSFileManager *fm = [NSFileManager defaultManager];

  if (depth >= 0) {
    // A generated GNUmakefile and its template declare the same names; a set
    // keeps one directory from being ambiguous with itself.
    NSMutableSet *declared = [NSMutableSet set];
    for (NSString *file in [NSArray arrayWithObjects: @"GNUmakefile", @"GNUmakefile.in", nil]) {
      NSString *text = [NSString stringWithContentsOfFile:
                        [directory stringByAppendingPathComponent: file]
                                                 encoding: NSUTF8StringEncoding error: NULL];
      if (text != nil) {
        [declared addObjectsFromArray: [self applicationNamesInMakefile: text]];
      }
    }
    for (NSString *name in declared) {
      NSMutableArray *dirs = [index objectForKey: name];
      if (dirs == nil) {
        dirs = [NSMutableArray array];
        [index setObject: dirs forKey: name];
      }
      [dirs addObject: directory];
    }
  }

  if (depth + 1 > (NSInteger)kMaxDepth) {
    return;
  }
  for (NSString *entry in [fm contentsOfDirectoryAtPath: directory error: NULL]) {
    if ([self skipsDirectoryNamed: entry]) {
      continue;
    }
    NSString *path = [directory stringByAppendingPathComponent: entry];
    NSString *type = [[fm attributesOfItemAtPath: path error: NULL] fileType];
    // A link could lead out of the tree or loop back into it.
    if (![type isEqualToString: NSFileTypeDirectory]) {
      continue;
    }
    [self indexDirectory: path depth: depth + 1 into: index];
  }
}

// Walks the root and stores the result; the entry is returned.
+ (NSDictionary *)rebuildIndexForRoot:(NSString *)root
{
  NSMutableDictionary *index = [NSMutableDictionary dictionary];
  [self indexDirectory: root depth: -1 into: index];
  walkCount++;

  NSDictionary *entry = [NSDictionary dictionaryWithObjectsAndKeys:
    index, kIndexKey,
    [NSNumber numberWithDouble: [NSDate timeIntervalSinceReferenceDate]], kBuiltKey,
    nil];
  if (indexes == nil) {
    indexes = [[NSMutableDictionary alloc] init];
  }
  [indexes setObject: entry forKey: root];
  return entry;
}

+ (NSString *)sourceDirectoryForApplicationName:(NSString *)name
                                     sourceRoot:(NSString *)root
{
  if ([name length] == 0 || [[name pathComponents] count] != 1 || [root length] == 0) {
    return nil;
  }
  @synchronized(self) {
    NSDictionary *entry = [indexes objectForKey: root];
    if (entry == nil) {
      entry = [self rebuildIndexForRoot: root];
    }
    NSArray *dirs = [[entry objectForKey: kIndexKey] objectForKey: name];
    if (dirs == nil) {
      NSTimeInterval age = [NSDate timeIntervalSinceReferenceDate]
        - [[entry objectForKey: kBuiltKey] doubleValue];
      if (age < rescanInterval) {
        return nil;
      }
      entry = [self rebuildIndexForRoot: root];
      dirs = [[entry objectForKey: kIndexKey] objectForKey: name];
    }
    if ([dirs count] > 1) {
      NSLog(@"[FlipSide] Application %@ is declared in more than one directory: %@",
            name, [dirs componentsJoinedByString: @", "]);
      return nil;
    }
    return [dirs firstObject];
  }
}

+ (NSString *)sourceDirectoryForApplicationName:(NSString *)name
{
  return [self sourceDirectoryForApplicationName: name sourceRoot: [self sourceRoot]];
}

@end
