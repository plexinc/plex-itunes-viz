/*
 *  Created by Elan Feingold on 7/10/2008.
 *  Copyright 2008 Blue Mandrill Design. All rights reserved.
 *
 */
#include "iTunesAPI.h"
#include "iTunesVisualAPI.h"
 
struct VIS_INFO
{
  bool bWantsFreq;
  int iSyncDelay;
};
typedef struct VIS_INFO VIS_INFO;

/*
 * Globals
 */
CFBundleRef         bundle;
VisualPluginProcPtr handlerProc;
void*               handlerData;
void*               refCon;
NSDictionary*       iTunesPrefs;
int                 options = 0;
bool                hasSentDisplay = false;
bool                isStopped = false;
CGrafPtr            displayPort = 0;
int                 x, y, w, h;
int                 timeBetweenCalls = 0;
char                strAlbumArtFile[1024];
int                 numWaveformChannels = 0;
int                 numSpectrumChannels = 0;
long                sampleTime = 0;
long                timestampID = 0;

#define VIS_ACTION_NEXT_PRESET    1
#define VIS_ACTION_PREV_PRESET    2
#define VIS_ACTION_LOAD_PRESET    3
#define VIS_ACTION_RANDOM_PRESET  4
#define VIS_ACTION_LOCK_PRESET    5
#define VIS_ACTION_ALBUM_ART      8

OSStatus ITAppProc(void *appCookie, OSType message, struct PlayerMessageInfo *messageInfo)
{
  switch (message)
  {
    case kPlayerRegisterVisualPluginMessage:
    {
      PlayerRegisterVisualPluginMessage* msg = &messageInfo->u.registerVisualPluginMessage;

      printf("kPlayerRegisterVisualPluginMessage\n");        
      printf(" -> Name: %s\n", msg->name);
      printf(" -> Options: 0x%08lx\n", msg->options);
      printf(" -> Handler: 0x%08lx (refcon=0x%08lx)\n", msg->handler, msg->registerRefCon);
      
      if (msg->options & kVisualWantsIdleMessages)
        printf(" -> Wants idle message.\n");
      if (msg->options & kVisualWantsConfigure)
        printf(" -> Wants configure.\n");
      if (msg->options & kVisualProvidesUnicodeName)
        printf(" -> Provides unicode name.\n");
      printf(" -> Requested %d spectrum channels.\n", msg->numSpectrumChannels);
      printf(" -> Requested %d waveform channels.\n", msg->numWaveformChannels);
      printf(" -> Time between data in ms: %d\n", msg->timeBetweenDataInMS);
      
      numSpectrumChannels = msg->numSpectrumChannels;
      numWaveformChannels = msg->numWaveformChannels;
      timeBetweenCalls = msg->timeBetweenDataInMS;
      options = msg->options;
      handlerProc = msg->handler;
      handlerData = msg->registerRefCon;
      break;
    }
    
    case kPlayerSetFullScreenOptionsMessage:
    {
      //printf("kPlayerSetFullScreenOptionsMessage\n");
      //PlayerSetFullScreenOptionsMessage* msg = &messageInfo->u.setFullScreenOptionsMessage;
      //printf(" -> Desired size: [%dx%d]", msg->desiredWidth, msg->desiredHeight);
      //printf(" -> Bit depth: %d to %d (prefer %d)", msg->minBitDepth, msg->maxBitDepth, msg->preferredBitDepth);
      break;
    }
    
    case kPlayerGetPluginITFileSpecMessage:
    {
      PlayerGetPluginITFileSpecMessage* msg = &messageInfo->u.getPluginITFileSpecMessage;
      CFURLRef cfUrl = CFBundleCopyExecutableURL(bundle);
      CFURLGetFSRef(cfUrl, msg->fileSpec);
      break;
    }
   
    case kPlayerGetPluginNamedDataMessage:
    {
      PlayerGetPluginNamedDataMessage* msg = &messageInfo->u.getPluginNamedDataMessage;
      printf("kPlayerGetPluginNamedDataMessage: %s\n", msg->dataName);
      break;
    }
    
    case kPlayerGetPluginFileSpecMessage:
    {
      printf("kPlayerGetPluginFileSpecMessage\n");
      PlayerGetPluginFileSpecMessage* msg = &messageInfo->u.getPluginFileSpecMessage;
    
      CFURLRef cfUrl = CFBundleCopyExecutableURL(bundle);
      
      FSRef fileRef;
      if (CFURLGetFSRef(cfUrl, &fileRef))
      {
        OSErr err = 0;
      
        printf("Get catalog information\n");
        if ((err=FSGetCatalogInfo(&fileRef, kFSCatInfoNone, NULL, NULL, msg->fileSpec, NULL)) != noErr)
          printf(" -> Error: %d\n", err);
        else
          printf(" -> Success\n");
      }

      break;
    }
    
    case kPlayerGetPluginDataMessage:
    {
      printf("kPlayerGetPluginDataMessage\n");
      PlayerGetPluginDataMessage* msg = &messageInfo->u.getPluginDataMessage;
      msg->dataSize = 0;
      break;
    }
    
    case kPlayerGetCurrentTrackCoverArtMessage:
    {
      printf("kPlayerGetCurrentTrackCoverArtMessage. Loading from %s\n", strAlbumArtFile);
      PlayerGetCurrentTrackCoverArtMessage* msg = &messageInfo->u.getCurrentTrackCoverArtMessage;
      msg->coverArt = 0;
      msg->coverArtFormat = 0;
      
      // Load file.
      NSString *path = [NSString stringWithUTF8String:strAlbumArtFile];
      NSData* imageData = [[NSData alloc] initWithContentsOfFile:path];
      if (imageData != nil)
      {
        // Copy over contents to handle.
        Handle handle;
        PtrToHand([imageData bytes], &handle, [imageData length]);

        // Fill in the message.
        msg->coverArt = handle;
        
        NSString* type = NSHFSTypeOfFile(path);
        NSLog(@"Type: %@ (length=%d)", type, [type length]);
        if ([type length] == 2)
        {
          msg->coverArtFormat = ('J' << 24) | ('P' << 16) | ('E' << 8) | 'G';
        }
        else
        {
          msg->coverArtFormat = NSHFSTypeCodeFromFileType(type);  
        }
          
        printf("Cover Art: %p\n", msg->coverArt);
        
        [type release];
        [imageData release];
      }
      
      [path release];
      
      break;
    }
    
    default:
    {
      printf("****** Called me for message %.4s\n", &message);
      break;
    }
  }

  return 0;
}

void Create(void* graphicsPort, int iPosX, int iPosY, int iWidth, int iHeight, const char* szVisualisationName, float fPixelRatio)
{
  // Save these.
  displayPort = (CGrafPtr)graphicsPort;
  x = iPosX;
  y = iPosY;
  w = iWidth;
  h = iHeight;
  printf("Device is %p @ %d,%d %dx%d\n", graphicsPort, x, y, w, h);

  CFURLRef pluginsURL = CFURLCreateWithFileSystemPath(kCFAllocatorDefault, CFSTR("/Users/elan/Library/iTunes/iTunes Plug-ins/"), kCFURLPOSIXPathStyle, true);
  CFArrayRef bundleArray = CFBundleCreateBundlesFromDirectory(kCFAllocatorDefault, pluginsURL, NULL);
  
  int i = 6;
  bundle = (CFBundleRef)CFArrayGetValueAtIndex(bundleArray, i);
  printf("---------------------------------------------\n");
  printf("Bundle: %08lx\n", bundle);
   
  PluginProcPtr proc = CFBundleGetFunctionPointerForName(bundle, CFSTR("iTunesPluginMainMachO"));
  printf("Plug-in proc: %08lx\n", proc);
  
  // Initialize.
  PluginInitMessage initMsg;
  initMsg.majorVersion = kITPluginMajorMessageVersion;
  initMsg.minorVersion = kITPluginMinorMessageVersion;
  initMsg.appCookie = (void* )0xdeadbeef;
  initMsg.appProc = ITAppProc;
  initMsg.options = 0;
  initMsg.refCon = 0;
  
  proc(kPluginInitMessage, (PluginMessageInfo* )&initMsg, (void* )0xbeef);
  printf("Refcon: %08lx\n", initMsg.refCon);
  
  if (initMsg.options & kPluginWantsIdleMessages)
    printf(" -> Wants idle message.\n");
  if (initMsg.options & kPluginWantsToBeLeftOpen)
    printf(" -> Wants to be left open.\n");
  if (initMsg.options & kPluginWantsVolumeMessages)
    printf(" -> Wants volume message.\n");
  if (initMsg.options & kPluginWantsDisplayNotification)
    printf(" -> Wants display notifications.\n");
      
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
  printf(" -> Visual plug-in initialization refcon=%p\n", initVizMsg.refCon);
  handlerData = initVizMsg.refCon;
  
  // Check our options.
  if (initMsg.options & kVisualDoesNotNeedResolutionSwitch)
    printf(" -> Does not need resolution refresh switch\n");
  if (initMsg.options & kVisualDoesNotNeedErase)
    printf(" -> Does not need erase\n");
    
  // Enable the plugin.
  printf("Enabling the plugin...\n");
  VisualPluginMessageInfo enableMsg;
  handlerProc(kVisualPluginEnableMessage, &enableMsg, handlerData);
  printf("Enabled.\n");
}

void Render()
{
  if (isStopped == true)
    return;

  if (options & kVisualWantsIdleMessages)
  {
    VisualPluginIdleMessage idleMsg;
    idleMsg.timeBetweenDataInMS = 20;
    handlerProc(kVisualPluginIdleMessage, (struct VisualPluginMessageInfo* )&idleMsg, handlerData);
  }
  
  // Tell plugin to update.
  handlerProc(kVisualPluginUpdateMessage, 0, handlerData);
}

void toPascal(char* str, Str255 strPascal)
{
  strPascal[0] = (int)strlen(str);
  strcpy((char* )&strPascal[1], str);
}

void Start(int iChannels, int iSamplesPerSec, int iBitsPerSample, const char* szSongName)
{
  printf("Start [%s]\n", szSongName);
  isStopped = false;
  sampleTime = 0;
}

void Display()
{
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

  printf("Telling something is playing\n");
  handlerProc(kVisualPluginPlayMessage, (struct VisualPluginMessageInfo* )&playMsg, handlerData);
  
  if (hasSentDisplay == false)
  {
    // Show the window.
    VisualPluginShowWindowMessage showMsg;
    showMsg.drawRect.left = x;
    showMsg.drawRect.top = y+21;
    showMsg.drawRect.right = w;
    showMsg.drawRect.bottom = h;
    showMsg.options = 0;
    showMsg.totalVisualizerRect.left = x;
    showMsg.totalVisualizerRect.top = y+21;
    showMsg.totalVisualizerRect.right = w;
    showMsg.totalVisualizerRect.bottom = h;
    showMsg.port = displayPort;
    
    printf("Telling it to show window\n");
    handlerProc(kVisualPluginShowWindowMessage, (struct VisualPluginMessageInfo* )&showMsg, handlerData);
    hasSentDisplay = true;
  }
}

void Stop()
{
  printf("Stop\n");
  handlerProc(kVisualPluginHideWindowMessage, (struct VisualPluginMessageInfo* )0x0, handlerData);
  isStopped = true;
  hasSentDisplay = false;
}

void Plex_iTunes_AudioData(short* pAudioData, int iAudioDataLength, float *pFreqData, int iFreqDataLength)
{
  if (isStopped == true)
    return;

  RenderVisualData visualData;
  memset(&visualData, 0, sizeof(visualData));
  visualData.numSpectrumChannels = numSpectrumChannels;
  visualData.numWaveformChannels = numWaveformChannels;
 
  int index = 0; 
  for (int x=0; x<iAudioDataLength*2; x+=2)
  {
    visualData.waveformData[0][index] = (pAudioData[x] + 32768)   >> 8;
    visualData.waveformData[1][index] = (pAudioData[x+1] + 32768) >> 8;
    index++;
  }

  for (int x=0; x<iFreqDataLength; x+=2)
  {
    visualData.spectrumData[0][x] = pFreqData[x]/600.0*256;
    visualData.spectrumData[1][x] = pFreqData[x+1]/600.0*256;
  }

  VisualPluginRenderMessage renderMsg;
  renderMsg.currentPositionInMS = sampleTime;
  renderMsg.timeStampID = timestampID++;
  renderMsg.renderData = &visualData;  
  handlerProc(kVisualPluginRenderMessage, (struct VisualPluginMessageInfo* )&renderMsg, handlerData);
  
  // Update the time.
  VisualPluginSetPositionMessage posMsg;
  posMsg.positionTimeInMS = sampleTime;
  handlerProc(kVisualPluginSetPositionMessage, (struct VisualPluginMessageInfo* )&posMsg, handlerData);
  
  sampleTime += 16;
}

void GetInfo(VIS_INFO* pInfo)
{
  pInfo->bWantsFreq = true;
  pInfo->iSyncDelay = 0;
}

bool OnAction(long cmd, void *param)
{
  bool ret = false;
  
  switch (cmd)
  {
    case VIS_ACTION_NEXT_PRESET: printf("Next preset\n"); break;
    case VIS_ACTION_PREV_PRESET: printf("Prev preset\n"); break;
    case VIS_ACTION_LOAD_PRESET: printf("Load preset\n"); break;
    case VIS_ACTION_RANDOM_PRESET: printf("Random preset\n"); break;
    case VIS_ACTION_LOCK_PRESET: printf("Lock preset\n"); break;
    case VIS_ACTION_ALBUM_ART:
      printf("Album file is [%s]\n", param);
      strcpy(strAlbumArtFile, (char*)param);
      Display();
    break;
  }
  
  return ret;
}

void GetPresets(char ***pPresets, int *currentPreset, int *numPresets, bool *locked)
{
}

void GetSettings(void* setting)
{
  return;
}

void UpdateSetting(int num)
{
}

struct Visualisation
{
    void (*Create)(void* pd3dDevice, int iPosX, int iPosY, int iWidth, int iHeight, const char* szVisualisationName, float fPixelRatio);
    void (*Start)(int iChannels, int iSamplesPerSec, int iBitsPerSample, const char* szSongName);
    void (*AudioData)(short* pAudioData, int iAudioDataLength, float *pFreqData, int iFreqDataLength);
    void (*Render)();
    void (*Stop)();
    void (*GetInfo)(VIS_INFO* pInfo);
    bool (*OnAction)(long action, void *param);
    void (*GetSettings)(void* );
    void (*UpdateSetting)(int num);
    void (*GetPresets)(char ***pPresets, int *currentPreset, int *numPresets, bool *locked);
};

void get_module(struct Visualisation* pVisz)
{
  pVisz->Create = Create;
  pVisz->Start = Start;
  pVisz->AudioData = Plex_iTunes_AudioData;
  pVisz->Render = Render;
  pVisz->Stop = Stop;
  pVisz->GetInfo = GetInfo;
  pVisz->OnAction = OnAction;
  pVisz->GetSettings = GetSettings;
  pVisz->UpdateSetting = UpdateSetting;
  pVisz->GetPresets = GetPresets;
};