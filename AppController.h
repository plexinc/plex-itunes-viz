//
//  AppController.h
//  iTunesViz
//
//  Created by Elan Feingold on 7/6/2008.
//  Copyright 2008 Blue Mandrill Design. All rights reserved.
//

#import <Cocoa/Cocoa.h>


@interface AppController : NSObject {
  IBOutlet NSWindow* myWindow;
  IBOutlet NSView* myView;
}
- (IBAction)menuNew:(id)sender;
- (void)tick;
@end
