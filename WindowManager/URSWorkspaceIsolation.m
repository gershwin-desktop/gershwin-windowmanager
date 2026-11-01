/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "URSWorkspaceIsolation.h"

void URSStopContactingWorkspaceApplication(NSString *ownPort)
{
  NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
  NSMutableDictionary *arguments = [NSMutableDictionary dictionaryWithDictionary:
    [defaults volatileDomainForName: NSArgumentDomain]];

  // -[NSWorkspace _workspaceApplication] refuses to contact itself, the one
  // documented way out of all of its paths.  The argument domain, because
  // the session's global defaults name Workspace and would win over anything
  // weaker; volatile, because this is a fact about this process and not a
  // setting that may reach the disk.
  [arguments setObject: ownPort forKey: @"GSWorkspaceApplication"];
  [defaults removeVolatileDomainForName: NSArgumentDomain];
  [defaults setVolatileDomain: arguments forName: NSArgumentDomain];
}
