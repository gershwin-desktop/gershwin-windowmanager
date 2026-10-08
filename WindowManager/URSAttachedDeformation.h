/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "URSWindowDeformation.h"

@class URSWobblyModel;

// Bends a window attached to a wobbling parent (a drawer, a sheet) as a
// continuation of the parent's mesh: every point of the attached window is
// moved as much as the nearest point of the parent, so the seam stays
// closed and the attached window rides along its parent's edge.
@interface URSAttachedDeformation : NSObject <URSWindowDeformation>

- (instancetype)initWithParent:(URSWobblyModel *)parent;

@property (readonly, nonatomic) URSWobblyModel *parent;

@end
