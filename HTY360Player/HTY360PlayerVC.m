//
//  HTY360PlayerVC.m
//  HTY360Player
//
//  Created by  on 11/8/15.
//  Copyright © 2015 Hanton. All rights reserved.
//

#import "HTY360PlayerVC.h"
#import "HTYGLKVC.h"
#define ONE_FRAME_DURATION 0.03
#define HIDE_CONTROL_DELAY 5.0f
#define DEFAULT_VIEW_ALPHA 0.6f


NSString * const kTracksKey         = @"tracks";
NSString * const kPlayableKey		= @"playable";
NSString * const kCurrentItemKey	= @"currentItem";
NSString * const kStatusKey         = @"status";
NSString * const kEmptyBufferKey    = @"playbackBufferEmpty";
NSString * const kKeepUpKey         = @"playbackLikelyToKeepUp";

static void *AVPlayerDemoPlaybackViewControllerCurrentItemObservationContext = &AVPlayerDemoPlaybackViewControllerCurrentItemObservationContext;
static void *AVPlayerDemoPlaybackViewControllerStatusObservationContext = &AVPlayerDemoPlaybackViewControllerStatusObservationContext;
static void *AVPlayerItemStatusContext = &AVPlayerItemStatusContext;

@interface HTY360PlayerVC () {
    HTYGLKVC *_glkViewController;
    AVPlayerItemVideoOutput* _videoOutput;
    AVPlayer* _player;
    AVPlayerItem* _playerItem;
    dispatch_queue_t _myVideoOutputQueue;
    id _notificationToken;
    id _timeObserver;
    
    float mRestoreAfterScrubbingRate;
    BOOL seekToZeroBeforePlay;
    int _bufferNilCount;
}

@property (strong, nonatomic) NSURL *videoURL;
@property (assign, nonatomic) BOOL isFirstVideo;
@property (nonatomic, assign) BOOL isSeekInProgress;
@property (nonatomic, assign) CMTime chaseTime;
@property (nonatomic, assign) BOOL isNew;
@property (nonatomic, assign) CMTime lastTime;
@end

@implementation HTY360PlayerVC

- (instancetype)initWithNibName:(NSString *)nibNameOrNil bundle:(NSBundle *)nibBundleOrNil url:(NSURL*)url lastTime:(CMTime)lastTime{
    self = [super initWithNibName:nibNameOrNil bundle:nibBundleOrNil];
    if (self) {
        [self setVideoURL:url];
        self.lastTime = lastTime;
    }
    return self;
}

-(void)viewDidLoad {
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(applicationWillResignActive:)
                                                 name:UIApplicationWillResignActiveNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(applicationDidBecomeActive:)
                                                 name:UIApplicationDidBecomeActiveNotification
                                               object:nil];
    
    [self setupVideoPlaybackForURL:_videoURL isNew:true];
    [self configureGLKView];
    self.isFirstVideo = true;
}

- (void)applicationWillResignActive:(NSNotification *)notification {
    [self pause];
}

- (void)applicationDidBecomeActive:(NSNotification *)notification {
    [_player seekToTime:[_player currentTime]];
}

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (UIInterfaceOrientationMask)supportedInterfaceOrientations {
    return UIInterfaceOrientationMaskLandscapeRight;
}

-(void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    
    @try {
        [self removePlayerTimeObserver];
        [_playerItem removeObserver:self forKeyPath:kStatusKey];
        [_playerItem removeObserver:self forKeyPath:kKeepUpKey];
        [_playerItem removeObserver:self forKeyPath:kEmptyBufferKey];
        [_playerItem removeOutput:_videoOutput];
    } @catch(id anException) {
        //do nothing
    }
    
    _videoOutput = nil;
    _playerItem = nil;
    _player = nil;
}

#pragma mark video communication

- (CVPixelBufferRef)retrievePixelBufferToDraw {
    CMTime cmtime = [_playerItem currentTime];
    CVPixelBufferRef pixelBuffer = [_videoOutput copyPixelBufferForItemTime:cmtime itemTimeForDisplay:nil];
    
    if (cmtime.value > 0 && pixelBuffer == NULL) {
        _bufferNilCount++;
        if (_bufferNilCount > 100) {
            __weak typeof(self) weakSelf = self;
            dispatch_async( dispatch_get_main_queue(),
                           ^{
                               if (!weakSelf) {
                                   return;
                               }
                               
                               NSLog(@"reset player");
                               
                               HTY360PlayerVC *strongSelf = weakSelf;
                               
                               [strongSelf->_playerItem removeOutput:strongSelf->_videoOutput];
                               strongSelf->_videoOutput = nil;
                               
                               NSDictionary *pixBuffAttributes = @{(id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)};
                               strongSelf->_videoOutput = [[AVPlayerItemVideoOutput alloc] initWithPixelBufferAttributes:pixBuffAttributes];
                               [strongSelf->_videoOutput setDelegate:self queue:strongSelf->_myVideoOutputQueue];
                               
                               [strongSelf->_playerItem addOutput:strongSelf->_videoOutput];
                               [strongSelf->_player replaceCurrentItemWithPlayerItem:strongSelf->_playerItem];
                               [strongSelf->_videoOutput requestNotificationOfMediaDataChangeWithAdvanceInterval:ONE_FRAME_DURATION];
                               
                               strongSelf->_bufferNilCount = 0;
                           });
        }
    }
    return pixelBuffer;
}

#pragma mark video setting

-(void)setVideoURL:(NSURL *)videoURL{
    if (!_player) {
        [self setupVideoPlaybackForURL:videoURL isNew:true];
    }
    
}

- (void)setupVideoPlaybackForURL:(NSURL*)url isNew:(BOOL)isNew{
    _isNew = isNew;
    if (!_player) {
        NSDictionary *pixBuffAttributes = @{(id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)};
        _videoOutput = [[AVPlayerItemVideoOutput alloc] initWithPixelBufferAttributes:pixBuffAttributes];
        _myVideoOutputQueue = dispatch_queue_create("myVideoOutputQueue", DISPATCH_QUEUE_SERIAL);
        [_videoOutput setDelegate:self queue:_myVideoOutputQueue];
        _player = [[AVPlayer alloc] init];
    }
    
    // Do not take mute button into account
    NSError *error = nil;
    BOOL success = [[AVAudioSession sharedInstance]
                    setCategory:AVAudioSessionCategoryPlayback
                    error:&error];
    if (!success) {
        NSLog(@"Could not use AVAudioSessionCategoryPlayback", nil);
    }
    
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:url options:nil];
    
    NSArray *requestedKeys = [NSArray arrayWithObjects:kTracksKey, kPlayableKey, nil];
    __weak typeof(self) weakSelf = self;
    [asset loadValuesAsynchronouslyForKeys:requestedKeys completionHandler:^{
        
        dispatch_async( dispatch_get_main_queue(),
                       ^{
                           if (!weakSelf) {
                               return;
                           }
                           
                           HTY360PlayerVC *strongSelf = weakSelf;
                           
                           @try {
                               /* Make sure that the value of each key has loaded successfully. */
                               for (NSString *thisKey in requestedKeys) {
                                   NSError *error = nil;
                                   AVKeyValueStatus keyStatus = [asset statusOfValueForKey:thisKey error:&error];
                                   if (keyStatus == AVKeyValueStatusFailed) {
                                       [strongSelf assetFailedToPrepareForPlayback:error];
                                       NSLog(@"load failed.");
                                       return;
                                   }
                               }
                               
                               NSError* error = nil;
                               AVKeyValueStatus status = [asset statusOfValueForKey:kTracksKey error:&error];
                               if (status == AVKeyValueStatusLoaded) {
                                   if (strongSelf->_playerItem) {
                                       @try {
                                           [_playerItem removeObserver:self forKeyPath:kStatusKey];
                                           [_playerItem removeObserver:self forKeyPath:kKeepUpKey];
                                           [_playerItem removeObserver:self forKeyPath:kEmptyBufferKey];
                                           [_playerItem removeOutput:_videoOutput];
                                           //                                           [_player removeObserver:self forKeyPath:kCurrentItemKey];
                                       } @catch (NSException *exception) {
                                           //donothing
                                       }
                                   }
                                   strongSelf->_playerItem = [AVPlayerItem playerItemWithAsset:asset];
                                   
                                   
                                   [strongSelf->_playerItem addOutput:strongSelf->_videoOutput];
                                   [strongSelf->_player replaceCurrentItemWithPlayerItem:strongSelf->_playerItem];
                                   [strongSelf->_videoOutput requestNotificationOfMediaDataChangeWithAdvanceInterval:ONE_FRAME_DURATION];
                                   if (!CMTIME_IS_INVALID(weakSelf.lastTime)) {
                                       [strongSelf->_playerItem seekToTime:weakSelf.lastTime toleranceBefore:kCMTimeZero toleranceAfter:kCMTimeZero];
                                   }
                                   strongSelf->seekToZeroBeforePlay = NO;
                                   
                                   if (strongSelf.isFirstVideo) {
                                       strongSelf.isFirstVideo = false;
                                       /* When the player item has played to its end time we'll toggle
                                        the movie controller Pause button to be the Play button */
                                       [[NSNotificationCenter defaultCenter] addObserver:self
                                                                                selector:@selector(playerItemDidReachEnd:)
                                                                                    name:AVPlayerItemDidPlayToEndTimeNotification
                                                                                  object:strongSelf->_playerItem];
                                       
                                       [[NSNotificationCenter defaultCenter] addObserver:self
                                                                                selector:@selector(playerItemFailedToPlayToEndTime:)
                                                                                    name:AVPlayerItemFailedToPlayToEndTimeNotification
                                                                                  object:strongSelf->_playerItem];
                                   }
                                   
                                   [strongSelf->_playerItem addObserver:self
                                                             forKeyPath:kStatusKey
                                                                options:NSKeyValueObservingOptionInitial | NSKeyValueObservingOptionNew
                                                                context:AVPlayerDemoPlaybackViewControllerStatusObservationContext];
                                   
                                   //                                   [strongSelf->_player addObserver:self
                                   //                                                         forKeyPath:kCurrentItemKey
                                   //                                                            options:NSKeyValueObservingOptionInitial | NSKeyValueObservingOptionNew
                                   //                                                            context:AVPlayerDemoPlaybackViewControllerCurrentItemObservationContext];
                                   
                                   //                                   [strongSelf->_player addObserver:self
                                   //                                             forKeyPath:kRateKey
                                   //                                                options:NSKeyValueObservingOptionInitial | NSKeyValueObservingOptionNew
                                   //                                                context:AVPlayerDemoPlaybackViewControllerRateObservationContext];
                                   
                                   [strongSelf->_playerItem addObserver:self
                                                             forKeyPath:kKeepUpKey
                                                                options:NSKeyValueObservingOptionInitial | NSKeyValueObservingOptionNew
                                                                context:AVPlayerDemoPlaybackViewControllerStatusObservationContext];
                                   
                                   [strongSelf->_playerItem addObserver:self
                                                             forKeyPath:kEmptyBufferKey
                                                                options:NSKeyValueObservingOptionInitial | NSKeyValueObservingOptionNew
                                                                context:AVPlayerDemoPlaybackViewControllerStatusObservationContext];
                                   
                                   [strongSelf initScrubberTimer];
                                   [strongSelf syncScrubber];
                                   if (_player.rate != 0.f && !_isNew) {
                                       CMTime timeToSeek = _lastTime;
                                       if (!CMTIME_IS_INVALID(timeToSeek)) {
                                           [_playerItem seekToTime:timeToSeek];
                                       }
                                       
                                   }
                                   [strongSelf play];
                               }
                               else {
                                   NSLog(@"%@ Failed to load the tracks.", self);
                               }
                           } @catch (NSException *exception) {
                               NSLog(@"load failed. %@", exception);
                           }
                       });
    }];
}

#pragma mark rendering glk view management

- (void)configureGLKView
{
    _glkViewController = [[HTYGLKVC alloc] init];
    
    _glkViewController.videoPlayerController = self;
    
    [self.view insertSubview:_glkViewController.view atIndex:0];
    [self addChildViewController:_glkViewController];
    [_glkViewController didMoveToParentViewController:self];
    
    _glkViewController.view.frame = self.view.bounds;
}

- (void)removeGLKView
{
    _glkViewController.videoPlayerController = nil;
    [_glkViewController.view removeFromSuperview];
    [_glkViewController removeFromParentViewController];
    _glkViewController = nil;
}

#pragma mark play button management

-(void)play {
    if ([self isPlaying])
        return;
    
    /* If we are at the end of the movie, we must seek to the beginning first
     before starting playback. */
    if (YES == seekToZeroBeforePlay) {
        seekToZeroBeforePlay = NO;
        [_player seekToTime:kCMTimeZero];
    }
    
    [_player play];
}

- (void)pause {
    if (![self isPlaying])
        return;
    
    [_player pause];
}


#pragma mark slider progress management
/* Cancels the previously registered time observer. */
- (void)removePlayerTimeObserver {
    if (_timeObserver) {
        [_player removeTimeObserver:_timeObserver];
        [_timeObserver invalidate];
        _timeObserver = nil;
    }
}

- (void)initScrubberTimer {
    double interval = .1f;
    
    CMTime playerDuration = [self playerItemDuration];
    if (CMTIME_IS_INVALID(playerDuration)) {
        return;
    }
    
    double duration = CMTimeGetSeconds(playerDuration);
    if (isfinite(duration)) {
        CGRect bounds = [self.delegate getSliderBounds];
        
        CGFloat width = CGRectGetWidth(bounds);
        if (width == 0) {
            return;
        }
        interval = 0.5f * duration / width;
    }
    
    __weak HTY360PlayerVC* weakSelf = self;
    _timeObserver = [_player addPeriodicTimeObserverForInterval:CMTimeMakeWithSeconds(interval, NSEC_PER_SEC)
                     /* If you pass NULL, the main queue is used. */
                                                          queue:NULL
                                                     usingBlock:^(CMTime time) {
                                                         [weakSelf syncScrubber];
                                                     }];
    
}

- (CMTime)playerItemDuration {
    
    if (_playerItem.status == AVPlayerItemStatusReadyToPlay) {
        /*
         NOTE:
         Because of the dynamic nature of HTTP Live Streaming Media, the best practice
         for obtaining the duration of an AVPlayerItem object has changed in iOS 4.3.
         Prior to iOS 4.3, you would obtain the duration of a player item by fetching
         the value of the duration property of its associated AVAsset object. However,
         note that for HTTP Live Streaming Media the duration of a player item during
         any particular playback session may differ from the duration of its asset. For
         this reason a new key-value observable duration property has been defined on
         AVPlayerItem.
         
         See the AV Foundation Release Notes for iOS 4.3 for more information.
         */
        
        return([_playerItem duration]);
    }
    
    return(kCMTimeInvalid);
}

-(CMTime)playerCurrentTime{
    return ([_playerItem currentTime]);
}

- (void)syncScrubber {
    CMTime playerDuration = [self playerItemDuration];
    if (CMTIME_IS_INVALID(playerDuration)) {
        return;
    }
    
    double duration = CMTimeGetSeconds(playerDuration);
    if (isfinite(duration)) {
        float minValue = [self.delegate getSliderMin];
        float maxValue = [self.delegate getSliderMax];
        double time = CMTimeGetSeconds([_player currentTime]);
        CGFloat value = (maxValue - minValue) * time / duration + minValue;
        if (!self.isSeekInProgress) {
            [self.delegate setSliderValue:value];
            [self.delegate setCurrentTime:[self getPlayingItemCurrentTime]];
        }
        
    }
    
}


/* The user is dragging the movie controller thumb to scrub through the movie. */
- (IBAction)beginScrubbing:(id)sender
{
    mRestoreAfterScrubbingRate = [_player rate];
    [_player setRate:0.f];
    
    /* Remove previous timer. */
    [self removePlayerTimeObserver];
}

/* Set the player current time to match the scrubber position. */
- (IBAction)scrub:(id)sender
{
    
}

- (void)actuallySeekToTime
{
    self.isSeekInProgress = YES;
    CMTime seekTimeInProgress = self.chaseTime;
    [_player seekToTime:seekTimeInProgress toleranceBefore:kCMTimeZero
         toleranceAfter:kCMTimeZero completionHandler:
     ^(BOOL isFinished)
     {
         if (CMTIME_COMPARE_INLINE(seekTimeInProgress, ==, self.chaseTime))
             self.isSeekInProgress = NO;
         else
             [self trySeekToChaseTime];
     }];
}


- (void)stopPlayingAndSeekSmoothlyToTime:(CMTime)newChaseTime
{
    [_player pause];
    
    if (CMTIME_COMPARE_INLINE(newChaseTime, !=, self.chaseTime))
    {
        self.chaseTime = newChaseTime;
        
        if (!self.isSeekInProgress)
            [self trySeekToChaseTime];
    }
}

- (void)trySeekToChaseTime
{
    if (_player.status == AVPlayerItemStatusUnknown)    {
        // wait until item becomes ready (KVO player.currentItem.status)
    }
    else if (_player.status == AVPlayerItemStatusReadyToPlay)    {
        [self actuallySeekToTime];
    }
}


/* The user has released the movie thumb control to stop scrubbing through the movie. */
- (void)endScrubbing:(UISlider*)slider{
    
    CMTime playerDuration = [self playerItemDuration];
    if (CMTIME_IS_INVALID(playerDuration)) {
        return;
    }
    
    double duration = CMTimeGetSeconds(playerDuration);
    if (isfinite(duration)) {
        float minValue = [slider minimumValue];
        float maxValue = [slider maximumValue];
        float value = [slider value];
        
        double time = duration * (value - minValue) / (maxValue - minValue);
        [self stopPlayingAndSeekSmoothlyToTime:CMTimeMakeWithSeconds(time, NSEC_PER_SEC)];
    }
    
    
    if (!_timeObserver) {
        CMTime playerDuration = [self playerItemDuration];
        if (CMTIME_IS_INVALID(playerDuration)) {
            return;
        }
        
        double duration = CMTimeGetSeconds(playerDuration);
        if (isfinite(duration)) {
            CGFloat width = CGRectGetWidth([self.delegate getSliderBounds]);
            double tolerance = 0.5f * duration / width;
            
            __weak HTY360PlayerVC* weakSelf = self;
            _timeObserver = [_player addPeriodicTimeObserverForInterval:CMTimeMakeWithSeconds(tolerance, NSEC_PER_SEC)
                                                                  queue:NULL
                                                             usingBlock:^(CMTime time) {
                                                                 [weakSelf syncScrubber];
                                                             }];
        }
    }
    
    if (mRestoreAfterScrubbingRate) {
        [_player setRate:mRestoreAfterScrubbingRate];
        mRestoreAfterScrubbingRate = 0.f;
    }
}

- (BOOL)isScrubbing {
    return mRestoreAfterScrubbingRate != 0.f;
}

- (void)observeValueForKeyPath:(NSString*) path
                      ofObject:(id)object
                        change:(NSDictionary*)change
                       context:(void*)context {
    /* AVPlayerItem "status" property value observer. */
    if (context == AVPlayerDemoPlaybackViewControllerStatusObservationContext)
    {
        if ([path isEqualToString:kStatusKey])
        {
            AVPlayerStatus status = [[change objectForKey:NSKeyValueChangeNewKey] integerValue];
            switch (status) {
                    /* Indicates that the status of the player is not yet known because
                     it has not tried to load new media resources for playback */
                case AVPlayerStatusUnknown: {
                    [self removePlayerTimeObserver];
                    [self syncScrubber];
                    if (self.delegate) {
                        [self.delegate disableScrubber];
                        [self.delegate playerUnknown];
                    }
                }
                    break;
                    
                case AVPlayerStatusReadyToPlay: {
                    /* Once the AVPlayerItem becomes ready to play, i.e.
                     [playerItem status] == AVPlayerItemStatusReadyToPlay,
                     its duration can be fetched from the item. */
                    
                    [self initScrubberTimer];
                    if (self.delegate) {
                        [self.delegate playerReadyToPlay];
                        [self.delegate enableScrubber];
                    }
                }
                    break;
                    
                case AVPlayerStatusFailed: {
                    AVPlayerItem *playerItem = (AVPlayerItem *)object;
                    [self assetFailedToPrepareForPlayback:playerItem.error];
                    NSLog(@"Error fail : %@", playerItem.error);
                    if (self.delegate) {
                        [self.delegate playerFailed];
                    }
                }
                    break;
            }
        }
        else if ([path isEqualToString:kKeepUpKey])
        {
            if (_playerItem.playbackLikelyToKeepUp) {
                
                NSLog(@"continue to play");
                [_player play];
                if (self.delegate) {
                    [self.delegate playerContinueToPlay];
                }
            }
        }
        else if ([path isEqualToString:kEmptyBufferKey])
        {
            if (_playerItem.playbackBufferEmpty) {
                NSLog(@"playback buffer empty, continue to play after 1 second.");
                if (self.delegate) {
                    [self.delegate playerBufferEmpty];
                }
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    [_player play];
                });
            }
        }
    }
    else if (context == AVPlayerDemoPlaybackViewControllerCurrentItemObservationContext) {
        
    }
    else {
        [super observeValueForKeyPath:path ofObject:object change:change context:context];
    }
}

-(void)assetFailedToPrepareForPlayback:(NSError *)error {
    [self removePlayerTimeObserver];
    [self syncScrubber];
    [self.delegate disableScrubber];
}

- (BOOL)isPlaying {
    return mRestoreAfterScrubbingRate != 0.f || [_player rate] != 0.f;
}

/* Called when the player item has played to its end time. */
- (void)playerItemDidReachEnd:(NSNotification *)notification {
    /* After the movie has played to its end time, seek back to time zero
     to play it again. */
    [self.delegate playerItemDidReachEnd];
}

- (void)playerItemFailedToPlayToEndTime:(NSNotification *)notification
{
    // play failed, continue to play
    NSLog(@"playerItemFailedToPlayToEndTime, continue to play after 1 second.");
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [_player play];
    });
}


#pragma mark video out delegate

- (float)getPlayingItemCurrentTime{
    CMTime itemCurrentTime = [[_player currentItem] currentTime];
    float current = CMTimeGetSeconds(itemCurrentTime);
    if (CMTIME_IS_INVALID(itemCurrentTime) || !isfinite(current))
        return 0.0f;
    else
        return current;
}

-(CMTime)getDuration{
    return [self playerItemDuration];
}

-(void)removeAllObservers{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [self removePlayerTimeObserver];
}

-(AVPlayerItemStatus)getPlayerStatus{
    return _playerItem.status;
}

@end
