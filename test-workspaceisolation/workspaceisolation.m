/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <AppKit/AppKit.h>
#import <GNUstepGUI/GSServicesManager.h>
#import "Testing.h"
#import "URSWorkspaceIsolation.h"

/* The name libs-gui looks up in NSWorkspace before talking to anybody. */
static NSString * const kWorkspaceDefault = @"GSWorkspaceApplication";

@interface NSWorkspace (URSPrivate)
- (id)_workspaceApplication;
@end

/* What the session's defaults carry: this name wins over the registration
 * domain, so a weaker domain could not take the workspace application away. */
static void setUserWorkspaceApplication(NSString *name)
{
  NSUserDefaults *defs = [NSUserDefaults standardUserDefaults];
  NSMutableDictionary *global = [NSMutableDictionary dictionaryWithDictionary:
    [defs volatileDomainForName: NSArgumentDomain]];

  [global setObject: name forKey: kWorkspaceDefault];
  [defs removeVolatileDomainForName: NSArgumentDomain];
  [defs setVolatileDomain: global forName: NSArgumentDomain];
}

int main(void)
{
  NSAutoreleasePool *arp = [NSAutoreleasePool new];
  NSUserDefaults *defs = [NSUserDefaults standardUserDefaults];
  NSString *const ownPort = @"URSTestWindowManager";

  setUserWorkspaceApplication(@"URSTestNoSuchWorkspace");
  URSStopContactingWorkspaceApplication(ownPort);
  PASS_EQUAL([defs stringForKey: kWorkspaceDefault], ownPort,
             "this process counts as its own workspace application");

  URSStopContactingWorkspaceApplication(ownPort);
  PASS_EQUAL([defs stringForKey: kWorkspaceDefault], ownPort,
             "doing it twice changes nothing");

  /* -[NSWorkspace _workspaceApplication] gives up without any Distributed
   * Objects, launch or panel only when the name is the process's own port. */
  {
    GSServicesManager *manager = [GSServicesManager manager];
    NSString *port;

    [manager registerAsServiceProvider];
    port = [manager port];
    NEED(PASS([port length] > 0, "a process with a services port"));
    URSStopContactingWorkspaceApplication(port);
    PASS([[NSWorkspace sharedWorkspace] _workspaceApplication] == nil,
         "NSWorkspace does not reach for a workspace application");
    PASS([[NSWorkspace sharedWorkspace] launchedApplications] != nil,
         "the list of running applications still comes from the local table");
  }

  [arp release];
  return 0;
}
