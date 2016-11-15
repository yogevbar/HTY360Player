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
@end

@interface HTY360PlayerVC : UIViewController <AVPlayerItemOutputPullDelegate>

@property (weak, nonatomic) id<HTY360PlayerVCDelegate> delegate;
@property (strong, nonatomic) IBOutlet UIView *playerControlBackgroundView;

- (instancetype)initWithNibName:(NSString *)nibNameOrNil bundle:(NSBundle *)nibBundleOrNil url:(NSURL*)url;
- (CVPixelBufferRef)retrievePixelBufferToDraw;
- (void)toggleControls;

- (void)configureGLKView;
- (void)removeGLKView;
- (void)play;
- (void)pause;
- (void)gyroButtonRelocate;

@end
