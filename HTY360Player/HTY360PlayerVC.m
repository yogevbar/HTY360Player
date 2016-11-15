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
//NSString * const kRateKey			= @"rate";
NSString * const kCurrentItemKey	= @"currentItem";
NSString * const kStatusKey         = @"status";
NSString * const kEmptyBufferKey    = @"playbackBufferEmpty";
NSString * const kKeepUpKey         = @"playbackLikelyToKeepUp";

//static void *AVPlayerDemoPlaybackViewControllerRateObservationContext = &AVPlayerDemoPlaybackViewControllerRateObservationContext;
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

@property (strong, nonatomic) IBOutlet UIView *debugView;
@property (strong, nonatomic) IBOutlet UILabel *rollValueLabel;
@property (strong, nonatomic) IBOutlet UILabel *yawValueLabel;
@property (strong, nonatomic) IBOutlet UILabel *pitchValueLabel;
@property (strong, nonatomic) IBOutlet UILabel *orientationValueLabel;

@property (strong, nonatomic) IBOutlet UIButton *playButton;
@property (strong, nonatomic) IBOutlet UISlider *progressSlider;
@property (strong, nonatomic) IBOutlet UIButton *backButton;
@property (strong, nonatomic) IBOutlet UIButton *gyroButton;
@property (assign, nonatomic) BOOL isFirstVideo;
@end

@implementation HTY360PlayerVC

- (id)initWithNibName:(NSString *)nibNameOrNil bundle:(NSBundle *)nibBundleOrNil url:(NSURL*)url {
    self = [super initWithNibName:nibNameOrNil bundle:nibBundleOrNil];
    if (self) {
        [self setVideoURL:url];
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
    
    [self setupVideoPlaybackForURL:_videoURL];
    
    [self configureGLKView];
    
    [self configurePlayButton];
    [self configureProgressSlider];
    [self configureControleBackgroundView];
    [self configureBackButton];
    [self configureGyroButton];
    self.isFirstVideo = true;
    
#if SHOW_DEBUG_LABEL
    self.debugView.hidden = NO;
#endif
}

- (void)applicationWillResignActive:(NSNotification *)notification {
    [self pause];
}

- (void)applicationDidBecomeActive:(NSNotification *)notification {
    [self updatePlayButton];
    [_player seekToTime:[_player currentTime]];
}

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    
    [self setPlayerControlBackgroundView:nil];
    [self setPlayButton:nil];
    [self setProgressSlider:nil];
    [self setBackButton:nil];
}

- (UIInterfaceOrientationMask)supportedInterfaceOrientations {
    return UIInterfaceOrientationMaskLandscape;
}

-(void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    
    @try {
        [self removePlayerTimeObserver];
        [_playerItem removeObserver:self forKeyPath:kStatusKey];
        [_playerItem removeObserver:self forKeyPath:kKeepUpKey];
        [_playerItem removeObserver:self forKeyPath:kEmptyBufferKey];
        [_playerItem removeOutput:_videoOutput];
        [_player removeObserver:self forKeyPath:kCurrentItemKey];
        //        [_player removeObserver:self forKeyPath:kRateKey];
    } @catch(id anException) {
        //do nothing
    }
    
    _videoOutput = nil;
    _playerItem = nil;
    _player = nil;
}

-(void)viewWillAppear:(BOOL)animated {
    [self updatePlayButton];
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
        [self setupVideoPlaybackForURL:videoURL];
    }
    
}

-(void)setupVideoPlaybackForURL:(NSURL*)url {
    
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
                                           [_player removeObserver:self forKeyPath:kCurrentItemKey];
                                       } @catch (NSException *exception) {
                                           //donothing
                                       }
                                   }
                                   strongSelf->_playerItem = [AVPlayerItem playerItemWithAsset:asset];
                                   
                                   
                                   [strongSelf->_playerItem addOutput:strongSelf->_videoOutput];
                                   [strongSelf->_player replaceCurrentItemWithPlayerItem:strongSelf->_playerItem];
                                   [strongSelf->_videoOutput requestNotificationOfMediaDataChangeWithAdvanceInterval:ONE_FRAME_DURATION];
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
                                   
                                   [strongSelf->_player addObserver:self
                                                         forKeyPath:kCurrentItemKey
                                                            options:NSKeyValueObservingOptionInitial | NSKeyValueObservingOptionNew
                                                            context:AVPlayerDemoPlaybackViewControllerCurrentItemObservationContext];
                                   
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
                                   //
                                   //                                   // autoplay   linyize 2016.4.20
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

- (void)configurePlayButton
{
    _playButton.backgroundColor = [UIColor clearColor];
    _playButton.showsTouchWhenHighlighted = YES;
    
    [self disablePlayerButtons];
    
    [self updatePlayButton];
}

- (IBAction)playButtonTouched:(id)sender {
    [NSObject cancelPreviousPerformRequestsWithTarget:self];
    if ([self isPlaying]) {
        [self pause];
    } else {
        [self play];
    }
}

- (void)updatePlayButton {
    [_playButton setImage:[UIImage imageNamed:[self isPlaying] ? @"playback_pause" : @"playback_play"]
                 forState:UIControlStateNormal];
}

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
    [_playButton setImage:[UIImage imageNamed:@"playback_pause"] forState:UIControlStateNormal];
    
    [self scheduleHideControls];
}

- (void)pause {
    if (![self isPlaying])
        return;
    
    [_player pause];
    [_playButton setImage:[UIImage imageNamed:@"playback_play"] forState:UIControlStateNormal];
    
    [self scheduleHideControls];
}

#pragma mark progress slider management

-(void)configureProgressSlider {
    _progressSlider.continuous = NO;
    _progressSlider.value = 0;
    
    [_progressSlider setThumbImage:[UIImage imageNamed:@"thumb.png"] forState:UIControlStateNormal];
    [_progressSlider setThumbImage:[UIImage imageNamed:@"thumb.png"] forState:UIControlStateHighlighted];
}

#pragma mark back and gyro button management

-(void)configureBackButton {
    _backButton.backgroundColor = [UIColor clearColor];
    _backButton.showsTouchWhenHighlighted = YES;
}

-(void)configureGyroButton {
    _gyroButton.backgroundColor = [UIColor clearColor];
    _gyroButton.showsTouchWhenHighlighted = YES;
}

#pragma mark controls management

-(void)enablePlayerButtons {
    _playButton.enabled = YES;
}

-(void)disablePlayerButtons {
    _playButton.enabled = NO;
}

-(void)configureControleBackgroundView {
    _playerControlBackgroundView.layer.cornerRadius = 8;
}

-(void)toggleControls {
    if(_playerControlBackgroundView.hidden){
        [self showControlsFast];
    }else{
        [self hideControlsFast];
    }
    
    [self scheduleHideControls];
}

-(void)scheduleHideControls {
    if(!_playerControlBackgroundView.hidden) {
        [NSObject cancelPreviousPerformRequestsWithTarget:self];
        [self performSelector:@selector(hideControlsSlowly) withObject:nil afterDelay:HIDE_CONTROL_DELAY];
    }
}

-(void)hideControlsWithDuration:(NSTimeInterval)duration {
    _playerControlBackgroundView.alpha = DEFAULT_VIEW_ALPHA;
    [UIView animateWithDuration:duration
                          delay:0.0
                        options:UIViewAnimationOptionCurveEaseIn
                     animations:^(void) {
                         
                         _playerControlBackgroundView.alpha = 0.0f;
                     }
                     completion:^(BOOL finished){
                         if(finished)
                             _playerControlBackgroundView.hidden = YES;
                     }];
    
}

-(void)hideControlsFast {
    [self hideControlsWithDuration:0.2];
}

-(void)hideControlsSlowly {
    [self hideControlsWithDuration:1.0];
}

-(void)showControlsFast {
    _playerControlBackgroundView.alpha = 0.0;
    _playerControlBackgroundView.hidden = NO;
    [UIView animateWithDuration:0.2
                          delay:0.0
                        options:UIViewAnimationOptionCurveEaseIn
                     animations:^(void) {
                         
                         _playerControlBackgroundView.alpha = DEFAULT_VIEW_ALPHA;
                     }
                     completion:nil];
}

- (void)removeTimeObserverFro_player {
    if (_timeObserver) {
        [_player removeTimeObserver:_timeObserver];
        _timeObserver = nil;
    }
}

#pragma mark slider progress management

-(void)initScrubberTimer {
    double interval = .1f;
    
    CMTime playerDuration = [self playerItemDuration];
    if (CMTIME_IS_INVALID(playerDuration)) {
        return;
    }
    double duration = CMTimeGetSeconds(playerDuration);
    if (isfinite(duration)) {
        CGFloat width = CGRectGetWidth([_progressSlider bounds]);
        interval = 0.5f * duration / width;
    }
    
    
    //    __weak HTY360PlayerVC* weakSelf = self;
    //    _timeObserver = [_player addPeriodicTimeObserverForInterval:CMTimeMakeWithSeconds(interval, NSEC_PER_SEC)
    //                                                          queue:NULL /* If you pass NULL, the main queue is used. */
    //                                                     usingBlock:^(CMTime time)
    //                     {
    //                         [weakSelf syncScrubber];
    //                     }];
    
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

- (void)syncScrubber {
    CMTime playerDuration = [self playerItemDuration];
    if (CMTIME_IS_INVALID(playerDuration)) {
        _progressSlider.minimumValue = 0.0;
        return;
    }
    
    double duration = CMTimeGetSeconds(playerDuration);
    if (isfinite(duration)) {
        float minValue = [_progressSlider minimumValue];
        float maxValue = [_progressSlider maximumValue];
        double time = CMTimeGetSeconds([_player currentTime]);
        
        [_progressSlider setValue:(maxValue - minValue) * time / duration + minValue];
    }
}

/* The user is dragging the movie controller thumb to scrub through the movie. */
- (IBAction)beginScrubbing:(id)sender
{
    mRestoreAfterScrubbingRate = [_player rate];
    [_player setRate:0.f];
    
    /* Remove previous timer. */
    [self removeTimeObserverFro_player];
}

/* Set the player current time to match the scrubber position. */
- (IBAction)scrub:(id)sender
{
    if ([sender isKindOfClass:[UISlider class]]) {
        UISlider* slider = sender;
        
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
            
            [_player seekToTime:CMTimeMakeWithSeconds(time, NSEC_PER_SEC)];
        }
    }
}

/* The user has released the movie thumb control to stop scrubbing through the movie. */
- (IBAction)endScrubbing:(id)sender {
    if (!_timeObserver) {
        CMTime playerDuration = [self playerItemDuration];
        if (CMTIME_IS_INVALID(playerDuration)) {
            return;
        }
        
        double duration = CMTimeGetSeconds(playerDuration);
        if (isfinite(duration)) {
            CGFloat width = CGRectGetWidth([_progressSlider bounds]);
            double tolerance = 0.5f * duration / width;
            
            __weak HTY360PlayerVC* weakSelf = self;
            _timeObserver = [_player addPeriodicTimeObserverForInterval:CMTimeMakeWithSeconds(tolerance, NSEC_PER_SEC) queue:NULL usingBlock:
                             ^(CMTime time)
                             {
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

-(void)enableScrubber {
    _progressSlider.enabled = YES;
}

-(void)disableScrubber {
    _progressSlider.enabled = NO;
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
            [self updatePlayButton];
            
            AVPlayerStatus status = [[change objectForKey:NSKeyValueChangeNewKey] integerValue];
            switch (status) {
                    /* Indicates that the status of the player is not yet known because
                     it has not tried to load new media resources for playback */
                case AVPlayerStatusUnknown: {
                    [self removePlayerTimeObserver];
                    [self syncScrubber];
                    
                    [self disableScrubber];
                    [self disablePlayerButtons];
                    if (self.delegate) {
                        [self.delegate playerUnknown];
                    }
                }
                    break;
                    
                case AVPlayerStatusReadyToPlay: {
                    /* Once the AVPlayerItem becomes ready to play, i.e.
                     [playerItem status] == AVPlayerItemStatusReadyToPlay,
                     its duration can be fetched from the item. */
                    
                    [self initScrubberTimer];
                    
                    [self enableScrubber];
                    [self enablePlayerButtons];
                    if (self.delegate) {
                        [self.delegate playerReadyToPlay];
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
    //    else if (context == AVPlayerDemoPlaybackViewControllerRateObservationContext) {
    //        [self updatePlayButton];
    //        // NSLog(@"AVPlayerDemoPlaybackViewControllerRateObservationContext");
    //    }
    /* AVPlayer "currentItem" property observer.
     Called when the AVPlayer replaceCurrentItemWithPlayerItem:
     replacement will/did occur. */
    else if (context == AVPlayerDemoPlaybackViewControllerCurrentItemObservationContext) {
        //NSLog(@"AVPlayerDemoPlaybackViewControllerCurrentItemObservationContext");
    }
    else {
        [super observeValueForKeyPath:path ofObject:object change:change context:context];
    }
}

-(void)assetFailedToPrepareForPlayback:(NSError *)error {
    [self removePlayerTimeObserver];
    [self syncScrubber];
    [self disableScrubber];
    [self disablePlayerButtons];
    
    /* Display the error. */
    UIAlertView *alert = [[UIAlertView alloc] initWithTitle:[error localizedDescription] message:[error localizedFailureReason] delegate:nil cancelButtonTitle:NSLocalizedString(@"OK", @"OK action") otherButtonTitles:nil, nil];
    [alert show];
}

- (BOOL)isPlaying {
    return mRestoreAfterScrubbingRate != 0.f || [_player rate] != 0.f;
}

/* Called when the player item has played to its end time. */
- (void)playerItemDidReachEnd:(NSNotification *)notification {
    /* After the movie has played to its end time, seek back to time zero
     to play it again. */
    seekToZeroBeforePlay = YES;
}

- (void)playerItemFailedToPlayToEndTime:(NSNotification *)notification
{
    // play failed, continue to play
    NSLog(@"playerItemFailedToPlayToEndTime, continue to play after 1 second.");
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [_player play];
    });
}

#pragma mark gyro button
-(void)gyroButtonRelocate{
    if(_glkViewController.isUsingMotion) {
        [_glkViewController stopDeviceMotion];
    } else {
        [_glkViewController startDeviceMotion];
    }
    
    _gyroButton.selected = _glkViewController.isUsingMotion;
}

- (IBAction)gyroButtonTouched:(id)sender {
    [self gyroButtonRelocate];
}

#pragma mark back button

- (IBAction)backButtonTouched:(id)sender {
    [self removePlayerTimeObserver];
    
    [_player pause];
    
    [self removeGLKView];
    
    [self dismissViewControllerAnimated:YES completion:nil];
}

/* Cancels the previously registered time observer. */
-(void)removePlayerTimeObserver {
    if (_timeObserver) {
        [_player removeTimeObserver:_timeObserver];
        _timeObserver = nil;
    }
}

#pragma mark video out delegate

- (void)outputSequenceWasFlushed:(AVPlayerItemOutput *)output
{
    
}

- (void)outputMediaDataWillChange:(AVPlayerItemOutput *)sender
{
    
}

@end
