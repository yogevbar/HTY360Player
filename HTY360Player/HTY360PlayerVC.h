//
//  HTY360PlayerVC.h
//  HTY360Player
//
//  Created by  on 11/8/15.
//  Copyright © 2015 Hanton. All rights reserved.
//

#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>


@protocol HTY360PlayerVCDelegate
-(void)playerUnknown;
-(void)playerReadyToPlay;
-(void)playerFailed;
-(void)playerBufferEmpty;
-(void)playerContinueToPlay;
-(void)playerItemDidReachEnd;
-(void)disableScrubber;
-(void)enableScrubber;
-(void)showLoader;
-(void)hideLoader;
-(CGRect)getSliderBounds;
-(void)updateSliderMin:(float)min;
-(void)updateSliderMax:(float)max;
-(float)getSliderMin;
-(float)getSliderMax;
-(void)setSliderValue:(CGFloat)value;
-(void)setCurrentTime:(float)current;

@end

@interface HTY360PlayerVC : UIViewController <AVPlayerItemOutputPullDelegate>

@property (weak, nonatomic) id<HTY360PlayerVCDelegate> delegate;
@property (strong, nonatomic) IBOutlet UIView *playerControlBackgroundView;

- (instancetype)initWithNibName:(NSString *)nibNameOrNil bundle:(NSBundle *)nibBundleOrNil url:(NSURL*)url;
- (CVPixelBufferRef)retrievePixelBufferToDraw;
- (void)setVideoURL:(NSURL *)videoURL;
- (void)configureGLKView;
- (void)removeGLKView;
- (void)play;
- (void)pause;
- (void)setupVideoPlaybackForURL:(NSURL*)url isNew:(BOOL)isNew;
- (void)beginScrubbing:(UISlider*)slider;
- (void)scrub:(UISlider*)slider;
- (void)endScrubbing:(UISlider*)slider;
- (CMTime)getDuration;
- (void)removeAllObservers;
@end
