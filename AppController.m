//
//  AppController.m
//  iTunesViz
//
//  Created by Elan Feingold on 7/6/2008.
//  Copyright 2008 Blue Mandrill Design. All rights reserved.
//
#include <AGL/agl.h>
#import "AppController.h"
#include "iTunesAPI.h"
#include "iTunesVisualAPI.h"

CFBundleRef         bundle;
VisualPluginProcPtr handlerProc;
void*               handlerData;
void*               refCon;
NSDictionary*       iTunesPrefs;
int                 options = 0;

OSStatus ITAppProc(void *appCookie, OSType message, struct PlayerMessageInfo *messageInfo)
{
  switch (message)
  {
    case kPlayerRegisterVisualPluginMessage:
    {
      PlayerRegisterVisualPluginMessage* msg = &messageInfo->u.registerVisualPluginMessage;

      NSLog(@"kPlayerRegisterVisualPluginMessage");        
      NSLog(@" -> Name: %s", msg->name);
      NSLog(@" -> Options: 0x%08lx", msg->options);
      NSLog(@" -> Handler: 0x%08lx (refcon=0x%08lx)", msg->handler, msg->registerRefCon);
      
      if (msg->options & kVisualWantsIdleMessages)
        NSLog(@" -> Wants idle message.");
      if (msg->options & kVisualWantsConfigure)
        NSLog(@" -> Wants configure.");
      if (msg->options & kVisualProvidesUnicodeName)
        NSLog(@" -> Provides unicode name.");
      
      options = msg->options;
      handlerProc = msg->handler;
      handlerData = msg->registerRefCon;
      break;
    }
    
    case kPlayerSetFullScreenOptionsMessage:
    {
      //NSLog(@"kPlayerSetFullScreenOptionsMessage");
      //PlayerSetFullScreenOptionsMessage* msg = &messageInfo->u.setFullScreenOptionsMessage;
      //NSLog(@" -> Desired size: [%dx%d]", msg->desiredWidth, msg->desiredHeight);
      //NSLog(@" -> Bit depth: %d to %d (prefer %d)", msg->minBitDepth, msg->maxBitDepth, msg->preferredBitDepth);
      break;
    }
    
    case kPlayerGetPluginITFileSpecMessage:
    {
      PlayerGetPluginITFileSpecMessage* msg = &messageInfo->u.getPluginITFileSpecMessage;
      CFURLRef cfUrl = CFBundleCopyExecutableURL(bundle);
      CFURLGetFSRef(cfUrl, msg->fileSpec);
      NSLog(@"Bundle executable is at %@", cfUrl);
      break;
    }
   
    case kPlayerGetPluginNamedDataMessage:
    {
      PlayerGetPluginNamedDataMessage* msg = &messageInfo->u.getPluginNamedDataMessage;
      NSLog(@"kPlayerGetPluginNamedDataMessage: %s", msg->dataName);
      // NSStringRef strKey = @"";
      
      break;
    }
    
    case kPlayerGetPluginFileSpecMessage:
    {
      NSLog(@"kPlayerGetPluginFileSpecMessage");
      PlayerGetPluginFileSpecMessage* msg = &messageInfo->u.getPluginFileSpecMessage;
    
      CFURLRef cfUrl = CFBundleCopyExecutableURL(bundle);
      
      FSRef fileRef;
      if (CFURLGetFSRef(cfUrl, &fileRef))
      {
        OSErr err = 0;
      
        NSLog(@"Get catalog information for %p (%@)", msg->fileSpec, cfUrl);
        if ((err=FSGetCatalogInfo(&fileRef, kFSCatInfoNone, NULL, NULL, msg->fileSpec, NULL)) != noErr)
          NSLog(@" -> Error: %d", err);
        else
          NSLog(@" -> Success");
      }

      break;
    }
    
    case kPlayerGetPluginDataMessage:
    {
      NSLog(@"kPlayerGetPluginDataMessage");
      PlayerGetPluginDataMessage* msg = &messageInfo->u.getPluginDataMessage;
      msg->dataSize = 0;
      break;
    }
    
    case kPlayerGetCurrentTrackCoverArtMessage:
    {
      NSLog(@"kPlayerGetCurrentTrackCoverArtMessage");
      PlayerGetCurrentTrackCoverArtMessage* msg = &messageInfo->u.getCurrentTrackCoverArtMessage;
      
      // Load file.
      NSString *path = @"/Volumes/Drobo/New Music/Air - Pocket Symphony (2007)/folder.jpg";
      NSData* imageData = [[NSData alloc] initWithContentsOfFile:path];
      if (imageData != nil)
      {
        // Copy over contents to handle.
        Handle handle;
        PtrToHand([imageData bytes], &handle, [imageData length]);

        // Fill in the message.
        msg->coverArt = handle;
        
        NSString* type = NSHFSTypeOfFile(path);
        msg->coverArtFormat = NSHFSTypeCodeFromFileType(type);

        NSLog(@"Cover Art: %p, Cover Art Format: %s", msg->coverArt, msg->coverArtFormat);
        
        [type release];
        [imageData release];
      }
      
      [path release];
      
      break;
    }
    
    default:
    {
      NSLog(@"Called me for message %.4s", &message);
      break;
    }
  }

  return 0;
}

@implementation AppController

- (id)init 
{ 
    [super init]; 
    return self; 
}

void toPascal(char* str, Str255 strPascal)
{
  strPascal[0] = (int)strlen(str);
  strcpy((char* )&strPascal[1], str);
}

- (IBAction)menuNew:(id)sender 
{ 
  NSView* view = myView;
  
  // obtain window pixelformat
  NSOpenGLPixelFormatAttribute wattrs[] =
  {
    NSOpenGLPFADoubleBuffer,
    NSOpenGLPFAWindow,
    NSOpenGLPFANoRecovery,
    NSOpenGLPFAAccelerated,
    //NSOpenGLPFAColorSize, 32,
    //NSOpenGLPFAAlphaSize, 8,
    0
  };
  NSOpenGLPixelFormat* pixFmt = [[NSOpenGLPixelFormat alloc] initWithAttributes:wattrs];  
  NSOpenGLContext* newContext = [[NSOpenGLContext alloc] initWithFormat:pixFmt shareContext:nil];

  [pixFmt release];
    
  // associate with current view
  [newContext setView:view];
  [newContext makeCurrentContext];
  
  [newContext clearDrawable];

  CFURLRef pluginsURL = CFURLCreateWithFileSystemPath(kCFAllocatorDefault, CFSTR("/Users/elan/Library/iTunes/iTunes Plug-ins/"), kCFURLPOSIXPathStyle, true);
  CFArrayRef bundleArray = CFBundleCreateBundlesFromDirectory(kCFAllocatorDefault, pluginsURL, NULL);
  
  // Read iTunes preferences.
  iTunesPrefs = [NSDictionary dictionaryWithContentsOfFile:[NSString stringWithFormat:@"%@/Library/Preferences/com.apple.iTunes.plist", NSHomeDirectory()]];
  
  //int arrayCount = CFArrayGetCount(bundleArray);
  //for (int i=0; i<arrayCount; i++)
  int i = 3;
  {
    bundle = (CFBundleRef)CFArrayGetValueAtIndex(bundleArray, i);
    NSLog(@"---------------------------------------------");
    NSLog(@"Bundle: %08lx", bundle);
     
    PluginProcPtr proc = CFBundleGetFunctionPointerForName(bundle, CFSTR("iTunesPluginMainMachO"));
    NSLog(@"Plug-in proc: %08lx", proc);
    
    // Initialize.
    PluginInitMessage initMsg;
    initMsg.majorVersion = kITPluginMajorMessageVersion;
    initMsg.minorVersion = kITPluginMinorMessageVersion;
    initMsg.appCookie = (void* )0xdeadbeef;
    initMsg.appProc = ITAppProc;
    initMsg.options = 0;
    initMsg.refCon = 0;
    
    proc(kPluginInitMessage, (PluginMessageInfo* )&initMsg, (void* )0xbeef);
    NSLog(@"Refcon: %08lx", initMsg.refCon);
    
    if (initMsg.options & kPluginWantsIdleMessages)
      NSLog(@" -> Wants idle message.");
    if (initMsg.options & kPluginWantsToBeLeftOpen)
      NSLog(@" -> Wants to be left open.");
    if (initMsg.options & kPluginWantsVolumeMessages)
      NSLog(@" -> Wants volume message.");
    if (initMsg.options & kPluginWantsDisplayNotification)
      NSLog(@" -> Wants display notifications.");
        
    // Send the kVisualPluginInitMessage message.
    VisualPluginInitMessage initVizMsg;
    initVizMsg.messageMajorVersion = kITPluginMajorMessageVersion;
    initVizMsg.messageMinorVersion = kITPluginMinorMessageVersion;
    initVizMsg.appVersion.majorRev = 7;
    initVizMsg.appVersion.minorAndBugRev = 4;
    initVizMsg.appVersion.nonRelRev = 0;
    initVizMsg.appVersion.stage = 0x80;
    initVizMsg.appCookie = (void* )0xdeadbeef;
    initVizMsg.appProc = ITAppProc;
    initVizMsg.options = 0;
    initVizMsg.refCon = handlerData;
    handlerProc(kVisualPluginInitMessage, (struct VisualPluginMessageInfo* )&initVizMsg, handlerData);
    NSLog(@" -> Visual plug-in initialization refcon=%p", initVizMsg.refCon);
    handlerData = initVizMsg.refCon;
    
    // Check our options.
    if (initMsg.options & kVisualDoesNotNeedResolutionSwitch)
      NSLog(@" -> Does not need resolution refresh switch");
    if (initMsg.options & kVisualDoesNotNeedErase)
      NSLog(@" -> Does not need erase");
      
    // Enable the plugin.
    NSLog(@"Enabling the plugin...");
    VisualPluginMessageInfo enableMsg;
    handlerProc(kVisualPluginEnableMessage, &enableMsg, handlerData);
    NSLog(@"Enabled.");
    usleep(100000);
  
    // Send an idle message for good measure if the plug-in wants one.
    VisualPluginIdleMessage idleMsg;
    idleMsg.timeBetweenDataInMS = 20;

    if (options & kVisualWantsIdleMessages)
    {
      NSLog(@"Sending idle message.");
      //handlerProc(kVisualPluginIdleMessage, (struct VisualPluginMessageInfo* )&idleMsg, handlerData);
      NSLog(@" -> Sent.");
      usleep(100000);
    }
            
    // Tell it a track is playing.
    VisualPluginPlayMessage playMsg;
    ITTrackInfoV1 trackInfo;
    ITStreamInfoV1 streamInfo;
    ITTrackInfo trackInfoUnicode;
    ITStreamInfo streamInfoUnicode;
    memset(&playMsg, 0, sizeof(playMsg));
    memset(&trackInfo, 0, sizeof(playMsg));
    memset(&streamInfo, 0, sizeof(streamInfo));
    memset(&trackInfoUnicode, 0, sizeof(trackInfoUnicode));
    memset(&streamInfoUnicode, 0, sizeof(streamInfoUnicode));
    
    printf("playMsg:     %p\n", &playMsg);
    printf("trackInfo:   %p\n", &trackInfo);
    printf("UtrackInfo:  %p\n", &trackInfoUnicode);
    printf("streamInfo:  %p\n", &streamInfo);
    printf("UstreamInfo: %p\n", &streamInfoUnicode);
    
    playMsg.trackInfo = &trackInfo;
    playMsg.streamInfo = &streamInfo;
    playMsg.trackInfoUnicode = &trackInfoUnicode;
    playMsg.streamInfoUnicode = &streamInfoUnicode;
    
    playMsg.audioFormat.mBitsPerChannel = 16;
    playMsg.audioFormat.mBytesPerFrame = 32;
    playMsg.audioFormat.mBytesPerPacket = 512;
    playMsg.audioFormat.mChannelsPerFrame = 2;
    playMsg.audioFormat.mFormatFlags = 0;
    playMsg.audioFormat.mFramesPerPacket = 16;
    playMsg.audioFormat.mSampleRate = 44100.0;
        
    // Track info.
    toPascal("The Track", trackInfo.name);
    toPascal("The Album", trackInfo.album);
    toPascal("The Artist", trackInfo.artist);
    toPascal("Genre", trackInfo.genre);
    toPascal("filename.mp3", trackInfo.fileName);
    toPascal("MPEG Audio File", trackInfo.kind);
    trackInfo.trackNumber = 1;
    trackInfo.numTracks = 10;
    trackInfo.year = 2007;
    trackInfo.soundVolumeAdjustment = 0;
    toPascal("Flat", trackInfo.eqPresetName);
    toPascal("Comments", trackInfo.comments);
    trackInfo.totalTimeInMS = 20000;
    trackInfo.startTimeInMS = 0;
    trackInfo.stopTimeInMS = 20000;
    trackInfo.sizeInBytes = 3040444;
    trackInfo.bitRate = 225;
    trackInfo.sampleRateFixed = 44100;
    trackInfo.fileType = 'FLAC';
    
    trackInfo.validFields = kITTINameFieldMask | kITTIArtistFieldMask | kITTIAlbumFieldMask;
    trackInfo.attributes = 0;
    trackInfo.validAttributes = 0;
    
    // Stream info.
    streamInfo.streamMessage[0] = 0;
    streamInfo.streamTitle[0] = 0;
    streamInfo.streamURL[0] = 0;
    streamInfo.version = 1;
      
    // Unicode track.
    trackInfoUnicode.validFields = kITTIArtistFieldMask | kITTIAlbumFieldMask | kITTINameFieldMask;
    trackInfoUnicode.attributes = 0;
    trackInfoUnicode.validAttributes = 0;

    CFStringRef strAlbum = CFSTR("Album");
    CFStringGetCharacters(strAlbum, CFRangeMake(0, CFStringGetLength(strAlbum)), trackInfoUnicode.album);

    CFStringRef strArtist = CFSTR("Artist");
    CFStringGetCharacters(strArtist, CFRangeMake(0, CFStringGetLength(strArtist)), trackInfoUnicode.artist);

    CFStringRef strTrack = CFSTR("Track");
    CFStringGetCharacters(strTrack, CFRangeMake(0, CFStringGetLength(strTrack)), trackInfoUnicode.name);
    
    // Unicode stream.
    streamInfoUnicode.streamMessage[0] = 0;
    streamInfoUnicode.streamTitle[0] = 0;
    streamInfoUnicode.streamURL[0] = 0;
    streamInfoUnicode.version = 1;

    NSLog(@"Telling something is playing");
    handlerProc(kVisualPluginPlayMessage, (struct VisualPluginMessageInfo* )&playMsg, handlerData);
    
    // Show the window.
    VisualPluginShowWindowMessage showMsg;
    showMsg.drawRect.left = 0;
    showMsg.drawRect.top = 0;
    showMsg.drawRect.right = 640;
    showMsg.drawRect.bottom = 480;
    showMsg.options = 0;
    showMsg.totalVisualizerRect.left = 0;
    showMsg.totalVisualizerRect.top = 0;
    showMsg.totalVisualizerRect.right = 640;
    showMsg.totalVisualizerRect.bottom = 480;
        
    WindowRef refWindow = [myWindow windowRef];
    showMsg.port = GetWindowPort(refWindow);
    NSLog(@"Telling to show window");
    NSLog(@"Before: %p", aglGetCurrentContext());
    handlerProc(kVisualPluginShowWindowMessage, (struct VisualPluginMessageInfo* )&showMsg, handlerData);
    NSLog(@"After: %p", aglGetCurrentContext());
        
    [NSTimer scheduledTimerWithTimeInterval:0.1
                                             target:self
                                           selector:@selector(tick)
                                           userInfo:NULL
                                            repeats:YES];
  }
  
  NSLog(@"Done");
} 

- (void)tick
{
  RenderVisualData visualData;
  visualData.numSpectrumChannels = 2;
  visualData.numWaveformChannels = 2;
  for (int x=0; x<512; x++)
  {
    visualData.spectrumData[0][x] = x;
    visualData.spectrumData[1][x] = x;
  }

  VisualPluginRenderMessage renderMsg;
  renderMsg.currentPositionInMS = 0;
  renderMsg.timeStampID = 0;
  renderMsg.renderData = &visualData;
  
  handlerProc(kVisualPluginRenderMessage, (struct VisualPluginMessageInfo* )&renderMsg, handlerData);
  
  // Update the time.
  VisualPluginSetPositionMessage posMsg;
  posMsg.positionTimeInMS = 100;
  handlerProc(kVisualPluginSetPositionMessage, (struct VisualPluginMessageInfo* )&posMsg, handlerData);
  
  // Tell plug-in to update.
  handlerProc(kVisualPluginUpdateMessage, 0, handlerData);
}

@end 
