/*
 *  Created by Elan Feingold on 7/10/2008.
 *  Copyright 2008 Blue Mandrill Design. All rights reserved.
 *
 */
#include <algorithm>
#include <map>
#include <string>
#include <vector>

#include <AGL/agl.h>
#include "iTunesAPI.h"
#include "iTunesVisualAPI.h"

using namespace std;

struct Visualizer
{
  string name;
  int numSpectrumChannels;
  int numWaveformChannels;
  int timeBetweenCalls;
  int options;
  VisualPluginProcPtr handlerProc;
  void* handlerData;
  CFBundleRef bundle;
};

class RuntimeStringCmp 
{
 public:
    enum cmp_mode {normal, nocase};
 private:
    const cmp_mode mode;

  static bool nocase_compare(char c1, char c2) { return toupper(c1) < toupper(c2); }

 public:
  RuntimeStringCmp (cmp_mode m=nocase) : mode(m) {}

  bool operator() (const string& s1, const string& s2) const 
  { 
    if (mode == normal) 
      return s1<s2; 
    else
      return lexicographical_compare (s1.begin(), s1.end(), s2.begin(), s2.end(), nocase_compare);
  }
};
 
//
// Globals.
//
map<string, Visualizer*, RuntimeStringCmp> vizNameMap;

string theModule;
Visualizer* theVisualizer = 0;
 
void ScanForVisualizers();
 
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
Visualizer*         lastViz = 0;

void*               refCon;
NSDictionary*       iTunesPrefs;
bool                hasSentDisplay = false;
bool                isStopped = false;
long                sampleTime = 0;
CGrafPtr            displayPort = 0;
int                 x, y, w, h;
char                strAlbumArtFile[1024];
char                strArtist[1024], strAlbum[1024], strTrack[1024];
int                 theTrackNumber, theDiscNumber, theYear, theDuration;
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
      string vizName;

      if (msg->options & kVisualProvidesUnicodeName)
      {
        char strName[1024];
        CFStringRef string = CFStringCreateWithCharacters(kCFAllocatorDefault, msg->unicodeName, *msg->unicodeName+1);
        CFStringGetCString(string, strName, sizeof(strName), kCFStringEncodingUTF8);
        CFRelease(string);
        
        vizName = strName;
      }
      else
      {
        vizName = (const char* )(msg->name+1);
      }

      printf("kPlayerRegisterVisualPluginMessage\n");        
        printf(" -> Name: %s\n", vizName.c_str());
      //printf(" -> Options: 0x%08lx\n", msg->options);
      //printf(" -> Handler: 0x%08lx (refcon=0x%08lx)\n", msg->handler, msg->registerRefCon);
      
      //if (msg->options & kVisualWantsIdleMessages)
      //  printf(" -> Wants idle message.\n");
      //if (msg->options & kVisualWantsConfigure)
      //  printf(" -> Wants configure.\n");
      //printf(" -> Requested %d spectrum channels.\n", msg->numSpectrumChannels);
      //printf(" -> Requested %d waveform channels.\n", msg->numWaveformChannels);
      //printf(" -> Time between data in ms: %d\n", msg->timeBetweenDataInMS);
      
      Visualizer* viz = new Visualizer();
      viz->name = vizName;
      viz->numSpectrumChannels = msg->numSpectrumChannels;
      viz->numWaveformChannels = msg->numWaveformChannels;
      viz->timeBetweenCalls = msg->timeBetweenDataInMS;
      viz->options = msg->options;
      viz->handlerProc = msg->handler;
      viz->handlerData = msg->registerRefCon;
      viz->bundle = bundle;
      
      // Save the last visualizer, and put it into the map.
      lastViz = viz;
      vizNameMap[vizName] = viz;
      
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
      //printf("kPlayerGetPluginNamedDataMessage: %s\n", msg->dataName);
      break;
    }
    
    case kPlayerGetPluginFileSpecMessage:
    {
      printf("kPlayerGetPluginFileSpecMessage\n");
      PlayerGetPluginFileSpecMessage* msg = &messageInfo->u.getPluginFileSpecMessage;
    
      CFURLRef cfUrl = CFBundleCopyBundleURL(bundle);
      FSRef fileRef;
      if (CFURLGetFSRef(cfUrl, &fileRef))
      {
        OSErr err = 0;
        if ((err=FSGetCatalogInfo(&fileRef, kFSCatInfoNone, NULL, NULL, msg->fileSpec, NULL)) != noErr)
          printf(" -> Error: %d\n", err);
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
          msg->coverArtFormat = ('J' << 24) | ('P' << 16) | ('E' << 8) | 'G';
        else
          msg->coverArtFormat = NSHFSTypeCodeFromFileType(type);  
          
        //[imageData release];
      }
      
      //[path release];
      
      break;
    }
    
    default:
    {
      printf("****** Unhandled message %.4s\n", &message);
      break;
    }
  }

  return 0;
}

void Create(void* graphicsPort, int iPosX, int iPosY, int iWidth, int iHeight, const char* szVisualisationName, float fPixelRatio)
{
  // Save these.
  theModule = szVisualisationName;
  displayPort = (CGrafPtr)graphicsPort;
  x = iPosX;
  y = iPosY;
  w = iWidth;
  h = iHeight;
  printf("Device is %p @ %d,%d %dx%d\n", graphicsPort, x, y, w, h);
  
  // Make sure we've loaded the visualizers.
  ScanForVisualizers();
      
  Visualizer* viz = vizNameMap[szVisualisationName];
  if (viz)
  {
    // Enable the plugin.
    theVisualizer = viz;
    printf("Enabling %s...\n", viz->name.c_str());
    VisualPluginMessageInfo enableMsg;
    theVisualizer->handlerProc(kVisualPluginEnableMessage, &enableMsg, theVisualizer->handlerData);
    printf("Enabled.\n");
  }
}

void Render()
{
  if (isStopped == true)
    return;

  if (theVisualizer->options & kVisualWantsIdleMessages)
  {
    VisualPluginIdleMessage idleMsg;
    idleMsg.timeBetweenDataInMS = 20;
    theVisualizer->handlerProc(kVisualPluginIdleMessage, (struct VisualPluginMessageInfo* )&idleMsg, theVisualizer->handlerData);
  }
  
  // Tell plugin to update.
  theVisualizer->handlerProc(kVisualPluginUpdateMessage, 0, theVisualizer->handlerData);
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

  printf("Telling something is playing (handler: %p, data: %p)\n", theVisualizer->handlerProc, theVisualizer->handlerData);
  theVisualizer->handlerProc(kVisualPluginPlayMessage, (struct VisualPluginMessageInfo* )&playMsg, theVisualizer->handlerData);
  
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
    theVisualizer->handlerProc(kVisualPluginShowWindowMessage, (struct VisualPluginMessageInfo* )&showMsg, theVisualizer->handlerData);
    hasSentDisplay = true;
  }
}

void Stop()
{
  printf("Stop\n");
  theVisualizer->handlerProc(kVisualPluginStopMessage, 0x0, theVisualizer->handlerData);
  theVisualizer->handlerProc(kVisualPluginHideWindowMessage, 0x0, theVisualizer->handlerData);
  isStopped = true;
  hasSentDisplay = false;
}

#define TO_WAVEFORM(x) (UInt8)((((int)pAudioData[x]) + 32768) >> 8)

/////////////////////////////////////////////////////////////////////////////////////////////////////////////
void Plex_iTunes_AudioData(short* pAudioData, int iAudioDataLength, float *pFreqData, int iFreqDataLength)
{
  if (isStopped == true)
    return;

  RenderVisualData visualData;
  memset(&visualData, 0, sizeof(visualData));
  visualData.numSpectrumChannels = theVisualizer->numSpectrumChannels;
  visualData.numWaveformChannels = theVisualizer->numWaveformChannels;
 
  int index = 0;
  for (int x=0; x<iAudioDataLength*2; x+=2)
  {  
    visualData.waveformData[0][index] = (((int)pAudioData[x]) + 32768)   >> 8;
    visualData.waveformData[1][index] = (((int)pAudioData[x+1]) + 32768) >> 8;
    index++;
  }
  
  index = 0;
  float min=999, max=-999;
  for (int x=0; x<iFreqDataLength*2; x+=2)
  { 
    int val1 = pFreqData[x];
    int val2 = pFreqData[x+1];
  
    visualData.spectrumData[0][index] = MIN(val1, 255);
    visualData.spectrumData[1][index] = MIN(val2, 255);
    
    if (pFreqData[x] < min)
      min = pFreqData[x];
    if (pFreqData[x] > max)
      max = pFreqData[x];

    index++;
  }
      
  VisualPluginRenderMessage renderMsg;
  renderMsg.currentPositionInMS = sampleTime;
  renderMsg.timeStampID = timestampID++;
  renderMsg.renderData = &visualData;  
  theVisualizer->handlerProc(kVisualPluginRenderMessage, (struct VisualPluginMessageInfo* )&renderMsg, theVisualizer->handlerData);
  
  // Update the time.
  VisualPluginSetPositionMessage posMsg;
  posMsg.positionTimeInMS = sampleTime;
  theVisualizer->handlerProc(kVisualPluginSetPositionMessage, (struct VisualPluginMessageInfo* )&posMsg, theVisualizer->handlerData);
  
  sampleTime += 60;
}

/////////////////////////////////////////////////////////////////////////////////////////////////////////////
void Plex_iTunes_SetTrackInfo(const char* artist, const char* album, const char* track, int trackNumber, int discNumber, int year, int duration)
{
  strcpy(strArtist, artist);
  strcpy(strAlbum, album);
  strcpy(strTrack, track);
}

/////////////////////////////////////////////////////////////////////////////////////////////////////////////
bool Plex_iTunes_HandlesOwnDisplay()
{
  return true;
}

/////////////////////////////////////////////////////////////////////////////////////////////////////////////
void InitializeBundle(CFBundleRef bundle)
{
  //printf("---------------------------------------------\n");
  printf("Bundle: %08lx\n", bundle);
   
  PluginProcPtr proc = (PluginProcPtr)CFBundleGetFunctionPointerForName(bundle, CFSTR("iTunesPluginMainMachO"));
  //printf("Plug-in proc: %08lx\n", proc);
  
  // Initialize.
  PluginInitMessage initMsg;
  initMsg.majorVersion = kITPluginMajorMessageVersion;
  initMsg.minorVersion = kITPluginMinorMessageVersion;
  initMsg.appCookie = (void* )0xdeadbeef;
  initMsg.appProc = ITAppProc;
  initMsg.options = 0;
  initMsg.refCon = 0;
  
  proc(kPluginInitMessage, (PluginMessageInfo* )&initMsg, (void* )0xbeef);
  
#if 0
  printf("Refcon: %08lx\n", initMsg.refCon);
  printf("Created visualizer: %p\n", lastViz);
  
  if (initMsg.options & kPluginWantsIdleMessages)
    printf(" -> Wants idle message.\n");
  if (initMsg.options & kPluginWantsToBeLeftOpen)
    printf(" -> Wants to be left open.\n");
  if (initMsg.options & kPluginWantsVolumeMessages)
    printf(" -> Wants volume message.\n");
  if (initMsg.options & kPluginWantsDisplayNotification)
    printf(" -> Wants display notifications.\n");
#endif
      
  // Send the kVisualPluginInitMessage message.
  VisualPluginInitMessage initVizMsg;
  initVizMsg.messageMajorVersion = kITPluginMajorMessageVersion;
  initVizMsg.messageMinorVersion = kITPluginMinorMessageVersion;
  initVizMsg.appVersion.majorRev = 8;
  initVizMsg.appVersion.minorAndBugRev = 0;
  initVizMsg.appVersion.nonRelRev = 0;
  initVizMsg.appVersion.stage = 0x80;
  initVizMsg.appCookie = (void* )0xdeadbeef;
  initVizMsg.appProc = ITAppProc;
  initVizMsg.options = 0;
  initVizMsg.refCon = lastViz->handlerData;
  lastViz->handlerProc(kVisualPluginInitMessage, (struct VisualPluginMessageInfo* )&initVizMsg, lastViz->handlerData);
  printf(" -> Visual plug-in initialization [%s] refcon=%p\n", lastViz->name.c_str(), initVizMsg.refCon);
  lastViz->handlerData = initVizMsg.refCon;
  
  // Check our options.
  //if (initMsg.options & kVisualDoesNotNeedResolutionSwitch)
  //  printf(" -> Does not need resolution refresh switch\n");
  //if (initMsg.options & kVisualDoesNotNeedErase)
  //  printf(" -> Does not need erase\n");
}

/////////////////////////////////////////////////////////////////////////////////////////////////////////////
void ScanForVisualizers()
{
  // If we've already scanned, don't bother scanning again.
  if (vizNameMap.size() > 0)
    return;

  // Look for plug-ins.
  NSString *userPath = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/iTunes/iTunes Plug-ins"];
  CFURLRef   bundleUrlUser = CFURLCreateWithFileSystemPath(
                kCFAllocatorDefault,
                (CFStringRef)userPath,
                kCFURLPOSIXPathStyle,
                true);

  CFURLRef   bundleUrlSystem = CFURLCreateWithFileSystemPath(
                kCFAllocatorDefault,
                CFSTR("/Library/iTunes/iTunes Plug-ins"),
                kCFURLPOSIXPathStyle,
                true);

  CFArrayRef bundleArrayUser = CFBundleCreateBundlesFromDirectory(kCFAllocatorDefault, bundleUrlUser, NULL);
  for (int i=0; i<CFArrayGetCount(bundleArrayUser); i++)
  {
    bundle = (CFBundleRef)CFArrayGetValueAtIndex(bundleArrayUser, i);
    InitializeBundle(bundle);
  }

  CFArrayRef bundleArraySystem = CFBundleCreateBundlesFromDirectory(kCFAllocatorDefault, bundleUrlSystem, NULL);
  for (int i=0; i<CFArrayGetCount(bundleArraySystem); i++)
  {
    bundle = (CFBundleRef)CFArrayGetValueAtIndex(bundleArraySystem, i);
    InitializeBundle(bundle);
  }
  
  // Free.
  [userPath release];
  CFRelease(bundleUrlUser);
  CFRelease(bundleArrayUser);
  CFRelease(bundleArraySystem);
}

/////////////////////////////////////////////////////////////////////////////////////////////////////////////
void Plex_iTunes_GetVisualizers(char*** pVisualizers, int* count)
{
  *pVisualizers = 0;
  *count = 0;
  
  // Make sure we've scanned for visualizers.
  ScanForVisualizers();
  
  // Now iterate through and ask them all to register so that we know what visualizers they present.
  char** ppPresets = (char**)malloc(sizeof(char* )*vizNameMap.size());
  *count = vizNameMap.size();

  map<string, Visualizer* >::iterator it;
  int i = 0;
  for (it = vizNameMap.begin(); it != vizNameMap.end(); ++it)
    ppPresets[i++] = strdup(it->first.c_str());
      
  *pVisualizers = ppPresets;
}

/////////////////////////////////////////////////////////////////////////////////////////////////////////////
void Plex_iTunes_GetInfo(VIS_INFO* pInfo)
{
  pInfo->bWantsFreq = true;
  pInfo->iSyncDelay = 0;
}

/////////////////////////////////////////////////////////////////////////////////////////////////////////////
bool Plex_iTunes_OnAction(long cmd, void *param)
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

/////////////////////////////////////////////////////////////////////////////////////////////////////////////
void Plex_iTunes_GetPresets(char ***pPresets, int *currentPreset, int *numPresets, bool *locked)
{
  *pPresets = 0;
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
    void (*SetTrackInfo)(const char* artist, const char* album, const char* track, int trackNumber, int discNumber, int year, int duration);
    bool (*HandlesOwnDisplay)();
    void (*GetVisualizers)(char*** pVisualizers, int* count);
};

extern "C" void get_module(struct Visualisation* pVisz)
{
  pVisz->Create = Create;
  pVisz->Start = Start;
  pVisz->AudioData = Plex_iTunes_AudioData;
  pVisz->Render = Render;
  pVisz->Stop = Stop;
  pVisz->GetInfo = Plex_iTunes_GetInfo;
  pVisz->OnAction = Plex_iTunes_OnAction;
  pVisz->GetSettings = GetSettings;
  pVisz->UpdateSetting = UpdateSetting;
  pVisz->GetPresets = Plex_iTunes_GetPresets;
  pVisz->SetTrackInfo = Plex_iTunes_SetTrackInfo;
  pVisz->HandlesOwnDisplay = Plex_iTunes_HandlesOwnDisplay;
  pVisz->GetVisualizers = Plex_iTunes_GetVisualizers;
};