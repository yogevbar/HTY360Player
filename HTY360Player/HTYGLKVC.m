//
//  HTYGLKVC.m
//  HTY360Player
//
//  Created by  on 11/8/15.
//  Copyright © 2015 Hanton. All rights reserved.
//

#import "HTYGLKVC.h"
#import "GLProgram.h"
#import "HTY360PlayerVC.h"
#import <CoreMotion/CoreMotion.h>

#define MAX_OVERTURE 95.0
#define MIN_OVERTURE 25.0
#define DEFAULT_OVERTURE 85.0

#define ES_PI  (3.14159265f)

#define ROLL_CORRECTION ES_PI/2.0

// Color Conversion Constants (YUV to RGB) including adjustment from 16-235/16-240 (video range)

// BT.709, which is the standard for HDTV.
static const GLfloat kColorConversion709[] = {
    1.164,  1.164, 1.164,
    0.0, -0.213, 2.112,
    1.793, -0.533,   0.0,
};

// Uniform index.
enum {
    UNIFORM_MODELVIEWPROJECTION_MATRIX,
    UNIFORM_Y,
    UNIFORM_UV,
    UNIFORM_COLOR_CONVERSION_MATRIX,
    NUM_UNIFORMS
};
GLint uniforms[NUM_UNIFORMS];


@interface HTYGLKVC () {
    
    GLKMatrix4 _modelViewProjectionMatrix;
    
    GLuint _vertexArrayID;
    GLuint _vertexBufferID;
    GLuint _vertexIndicesBufferID;
    GLuint _vertexTexCoordID;
    GLuint _vertexTexCoordAttributeIndex;
    
    float _fingerRotationX;
    float _fingerRotationY;
    float _savedGyroRotationX;
    float _savedGyroRotationY;
    float _fPitchCorrection;
    float _fMouseRollCorrection;
    float _fRollCorrection;
    float _fRoll;
    
    Boolean _bInitializedCorrections;
    Boolean _bUpRight;
    
    CGFloat _overture;
    
    int _numIndices;
    
    CMMotionManager *_motionManager;
    CMAttitude *_referenceAttitude;
    
    CVOpenGLESTextureRef _lumaTexture;
    CVOpenGLESTextureRef _chromaTexture;
    CVOpenGLESTextureCacheRef _videoTextureCache;
    const GLfloat *_preferredConversion;
}

@property (strong, nonatomic) EAGLContext *context;
@property (strong, nonatomic) GLProgram *program;
@property (strong, nonatomic) NSMutableArray *currentTouches;

- (void)setupGL;
- (void)tearDownGL;
- (void)buildProgram;

@end

@implementation HTYGLKVC

@dynamic view;

- (void)viewDidLoad {
    [super viewDidLoad];
    
    self.context = [[EAGLContext alloc] initWithAPI:kEAGLRenderingAPIOpenGLES2];
    
    if (!self.context) {
        NSLog(@"Failed to create ES context");
    }
    
    GLKView *view = (GLKView *)self.view;
    view.context = self.context;
    view.drawableDepthFormat = GLKViewDrawableDepthFormat24;
    
    [[UIDevice currentDevice] beginGeneratingDeviceOrientationNotifications];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(detectOrientation) name:UIDeviceOrientationDidChangeNotification object:nil];
    
    UIPinchGestureRecognizer *pinchRecognizer = [[UIPinchGestureRecognizer alloc] initWithTarget:self action:@selector(handlePinchGesture:)];
    [view addGestureRecognizer:pinchRecognizer];
    
    self.preferredFramesPerSecond = 60.0f;
    
    _overture = DEFAULT_OVERTURE;
    
    // Set the default conversion to BT.709, which is the standard for HDTV.
    _preferredConversion = kColorConversion709;
    
    _fRoll = 0.0f;
    
    _fMouseRollCorrection = 0.0f;
    
    _bUpRight = false;
    
    [self setupGL];
    
    [self startDeviceMotion];
}

-(UIInterfaceOrientationMask) supportedInterfaceOrientations {
    return UIInterfaceOrientationMaskLandscape;
}

-(void) detectOrientation
{
    //[_motionManager stopDeviceMotionUpdates];
    //[_motionManager startDeviceMotionUpdatesUsingReferenceFrame:CMAttitudeReferenceFrameXMagneticNorthZVertical];
    //else if (orientation == UIDeviceOrientationPortrait )
    //  [_motionManager startDeviceMotionUpdatesUsingReferenceFrame:CMAttitudeReferenceFrameXArbitraryZVertical];
    
    //[self tearDownGL];
    
    //[self setupGL];
}

-(void) viewDidDisappear:(BOOL)animated
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    
    [[UIDevice currentDevice] endGeneratingDeviceOrientationNotifications];
}

- (void)dealloc {
    [self stopDeviceMotion];
    
    [self.view deleteDrawable];
    
    [self tearDownGL];
    
    if ([EAGLContext currentContext] == self.context) {
        [EAGLContext setCurrentContext:nil];
    }
    
    self.context = nil;
}

- (void)didReceiveMemoryWarning {
    [super didReceiveMemoryWarning];
    
    if ([self isViewLoaded] && ([[self view] window] == nil)) {
        self.view = nil;
        
        [self tearDownGL];
        
        if ([EAGLContext currentContext] == self.context) {
            [EAGLContext setCurrentContext:nil];
        }
        self.context = nil;
    }
    
    // Dispose of any resources that can be recreated.
}

#pragma mark generate sphere

int esGenSphere ( int numSlices, float radius, float **vertices, float **normals,
                 float **texCoords, uint16_t **indices, int *numVertices_out) {
    int i;
    int j;
    int numParallels = numSlices / 2;
    int numVertices = ( numParallels + 1 ) * ( numSlices + 1 );
    int numIndices = numParallels * numSlices * 6;
    float angleStep = (2.0f * ES_PI) / ((float) numSlices);
    
    if ( vertices != NULL )
        *vertices = (float*)malloc ( sizeof(float) * 3 * numVertices );
    
    // Pas besoin des normals pour l'instant
    //    if ( normals != NULL )
    //        *normals = malloc ( sizeof(float) * 3 * numVertices );
    
    if ( texCoords != NULL )
        *texCoords = (float*)malloc ( sizeof(float) * 2 * numVertices );
    
    if ( indices != NULL )
        *indices = (uint16_t*)malloc ( sizeof(uint16_t) * numIndices );
    
    for ( i = 0; i < numParallels + 1; i++ ) {
        for ( j = 0; j < numSlices + 1; j++ ) {
            int vertex = ( i * (numSlices + 1) + j ) * 3;
            
            if ( vertices ) {
                (*vertices)[vertex + 0] = radius * sinf ( angleStep * (float)i ) *
                sinf ( angleStep * (float)j );
                (*vertices)[vertex + 1] = radius * cosf ( angleStep * (float)i );
                (*vertices)[vertex + 2] = radius * sinf ( angleStep * (float)i ) *
                cosf ( angleStep * (float)j );
            }
            
            //            if ( normals )
            //            {
            //                (*normals)[vertex + 0] = (*vertices)[vertex + 0] / radius;
            //                (*normals)[vertex + 1] = (*vertices)[vertex + 1] / radius;
            //                (*normals)[vertex + 2] = (*vertices)[vertex + 2] / radius;
            //            }
            
            if (texCoords) {
                int texIndex = ( i * (numSlices + 1) + j ) * 2;
                (*texCoords)[texIndex + 0] = (float) j / (float) numSlices;
                (*texCoords)[texIndex + 1] = 1.0f - ((float) i / (float) (numParallels));
            }
        }
    }
    
    // Generate the indices
    if ( indices != NULL ) {
        uint16_t *indexBuf = (*indices);
        for ( i = 0; i < numParallels ; i++ ) {
            for ( j = 0; j < numSlices; j++ ) {
                *indexBuf++  = i * ( numSlices + 1 ) + j;
                *indexBuf++ = ( i + 1 ) * ( numSlices + 1 ) + j;
                *indexBuf++ = ( i + 1 ) * ( numSlices + 1 ) + ( j + 1 );
                
                *indexBuf++ = i * ( numSlices + 1 ) + j;
                *indexBuf++ = ( i + 1 ) * ( numSlices + 1 ) + ( j + 1 );
                *indexBuf++ = i * ( numSlices + 1 ) + ( j + 1 );
            }
        }
    }
    
    if (numVertices_out) {
        *numVertices_out = numVertices;
    }
    
    return numIndices;
}

#pragma mark setup gl

- (void)setupGL {
    [EAGLContext setCurrentContext:self.context];
    
    [self buildProgram];
    
    GLfloat *vVertices = NULL;
    GLfloat *vTextCoord = NULL;
    GLushort *indices = NULL;
    int numVertices = 0;
    _numIndices =  esGenSphere(200, 1.0f, &vVertices,  NULL,
                               &vTextCoord, &indices, &numVertices);
    
    glGenVertexArraysOES(1, &_vertexArrayID);
    glBindVertexArrayOES(_vertexArrayID);
    
    // Vertex
    glGenBuffers(1, &_vertexBufferID);
    glBindBuffer(GL_ARRAY_BUFFER, _vertexBufferID);
    glBufferData(GL_ARRAY_BUFFER,
                 numVertices*3*sizeof(GLfloat),
                 vVertices,
                 GL_STATIC_DRAW);
    glEnableVertexAttribArray(GLKVertexAttribPosition);
    glVertexAttribPointer(GLKVertexAttribPosition,
                          3,
                          GL_FLOAT,
                          GL_FALSE,
                          sizeof(GLfloat) * 3,
                          NULL);
    
    // Texture Coordinates
    glGenBuffers(1, &_vertexTexCoordID);
    glBindBuffer(GL_ARRAY_BUFFER, _vertexTexCoordID);
    glBufferData(GL_ARRAY_BUFFER,
                 numVertices*2*sizeof(GLfloat),
                 vTextCoord,
                 GL_DYNAMIC_DRAW);
    glEnableVertexAttribArray(_vertexTexCoordAttributeIndex);
    glVertexAttribPointer(_vertexTexCoordAttributeIndex,
                          2,
                          GL_FLOAT,
                          GL_FALSE,
                          sizeof(GLfloat) * 2,
                          NULL);
    
    //Indices
    glGenBuffers(1, &_vertexIndicesBufferID);
    glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, _vertexIndicesBufferID);
    glBufferData(GL_ELEMENT_ARRAY_BUFFER,
                 sizeof(GLushort) * _numIndices,
                 indices, GL_STATIC_DRAW);
    
    
    if (!_videoTextureCache) {
        CVReturn err = CVOpenGLESTextureCacheCreate(kCFAllocatorDefault, NULL, _context, NULL, &_videoTextureCache);
        if (err != noErr) {
            NSLog(@"Error at CVOpenGLESTextureCacheCreate %d", err);
            return;
        }
    }
    
    [_program use];
    glUniform1i(uniforms[UNIFORM_Y], 0);
    glUniform1i(uniforms[UNIFORM_UV], 1);
    glUniformMatrix3fv(uniforms[UNIFORM_COLOR_CONVERSION_MATRIX], 1, GL_FALSE, _preferredConversion);
    
    free(vVertices);
    free(vTextCoord);
    free(indices);
}

- (void)tearDownGL {
    [EAGLContext setCurrentContext:self.context];
    
    [self cleanUpTextures];
    
    glDeleteBuffers(1, &_vertexBufferID);
    glDeleteVertexArraysOES(1, &_vertexArrayID);
    glDeleteBuffers(1, &_vertexTexCoordID);
    
    _program = nil;
    
    if (_videoTextureCache)
    {
        CFRelease(_videoTextureCache);
        _videoTextureCache = NULL;
    }
}

#pragma mark texture cleanup

- (void)cleanUpTextures {
    if (_lumaTexture) {
        CFRelease(_lumaTexture);
        _lumaTexture = NULL;
    }
    
    if (_chromaTexture) {
        CFRelease(_chromaTexture);
        _chromaTexture = NULL;
    }
    
    // Periodic texture cache flush every frame
    CVOpenGLESTextureCacheFlush(_videoTextureCache, 0);
}

#pragma mark device motion management

- (void)startDeviceMotion {
    _isUsingMotion = NO;
    
    _motionManager = [[CMMotionManager alloc] init];
    _referenceAttitude = nil;
    _motionManager.deviceMotionUpdateInterval = 1.0 / 60.0;
    _motionManager.gyroUpdateInterval = 1.0f / 60;
    _motionManager.showsDeviceMovementDisplay = YES;
    
    /*
     if([_motionManager isGyroAvailable] == YES)
     {
     [_motionManager setGyroUpdateInterval:0.02];
     
     [_motionManager startGyroUpdates];
     }
     
     if([_motionManager isAccelerometerAvailable] == YES)
     {
     [_motionManager setAccelerometerUpdateInterval:0.02];
     
     [_motionManager startAccelerometerUpdates];
     }
     */
    
    [_motionManager startDeviceMotionUpdatesUsingReferenceFrame:CMAttitudeReferenceFrameXArbitraryCorrectedZVertical];
    
    //[_motionManager startDeviceMotionUpdatesUsingReferenceFrame:CMAttitudeReferenceFrameXTrueNorthZVertical];
    
    _referenceAttitude = _motionManager.deviceMotion.attitude; // Maybe nil actually. reset it later when we have data
    
    _savedGyroRotationX = 0;
    _savedGyroRotationY = 0;
    
    _fPitchCorrection = 0.0f;
    _fRollCorrection = 0.0f;
    
    _bInitializedCorrections = false;
    
    _isUsingMotion = YES;
}

- (void)stopDeviceMotion
{
    _fingerRotationX = _savedGyroRotationX -_referenceAttitude.roll - ROLL_CORRECTION;
    _fingerRotationY = _savedGyroRotationY;
    
    _isUsingMotion = NO;
    
    if([_motionManager isGyroActive] == YES)
        [_motionManager stopGyroUpdates];
    
    if([_motionManager isAccelerometerActive] == YES)
        [_motionManager stopAccelerometerUpdates];
    
    [_motionManager stopDeviceMotionUpdates];
    _motionManager = nil;
}

#pragma mark - GLKView and GLKViewController delegate methods

- (GLKQuaternion)CreateQuaternionWithYaw:(float)yaw roll:(float)roll pitch:(float) pitch{
    // Assuming the angles are in radians.
    float c1 = cos(yaw*0.5f);
    float s1 = sin(yaw*0.5f);
    float c2 = cos(roll*0.5f);
    float s2 = sin(roll*0.5f);
    float c3 = cos(pitch*0.5f);
    float s3 = sin(pitch*0.5f);
    float c1c2 = c1*c2;
    float s1s2 = s1*s2;
    
    return GLKQuaternionMake(c1c2*s3 + s1s2*c3, s1*c2*c3 + c1*s2*s3, c1*s2*c3 - s1*c2*s3, c1c2*c3 - s1s2*s3);
}


- (void)update
{
    float aspect = fabs(self.view.bounds.size.width / self.view.bounds.size.height);
    GLKMatrix4 projectionMatrix = GLKMatrix4MakePerspective(GLKMathDegreesToRadians(_overture), aspect, 0.1f, 400.0f);
    projectionMatrix = GLKMatrix4Rotate(projectionMatrix, ES_PI, 1.0f, 0.0f, 0.0f);
    
    GLKMatrix4 modelViewMatrix = GLKMatrix4Identity;
    modelViewMatrix = GLKMatrix4Scale(modelViewMatrix, 300.0, 300.0, 300.0);
    
    if(_isUsingMotion)
    {
        CMDeviceMotion *d = _motionManager.deviceMotion;
        
        if (d != nil)
        {
            CMAttitude *attitude = d.attitude;
            
            //GLKVector3 v3Gyro = GLKVector3Make(_motionManager.gyroData.rotationRate.x, _motionManager.gyroData.rotationRate.y, _motionManager.gyroData.rotationRate.z);
            
            //GLKVector3 vAccel = GLKVector3Make(_motionManager.accelerometerData.acceleration.x, _motionManager.accelerometerData.acceleration.y, _motionManager.accelerometerData.acceleration.z);
            
            GLKVector3 vGravity = GLKVector3Make( d.gravity.x, d.gravity.y, d.gravity.z );
            
            if( _bInitializedCorrections == false )
            {
                _referenceAttitude = d.attitude;
                _bInitializedCorrections = true;
            }
            
            //NSLog(@"Gyro X: %.2f Gyro Y: %.2f, Gyro Z: %.2f", v3Gyro.x, v3Gyro.y, v3Gyro.z);
            //NSLog(@"Accel X: %.2f Accel Y: %.2f, Accel Z: %.2f", vAccel.x, vAccel.y, vAccel.z);
            //NSLog(@"Gravity X: %.2f Gravity Y: %.2f, Gravity Z: %.2f", vGravity.x, vGravity.y, vGravity.z);
            //NSLog(@"Yaw: %.2f Pitch: %.2f, Roll: %.2f", attitude.yaw, attitude.pitch, attitude.roll);
            
            /*
             if (_referenceAttitude != nil) {
             [attitude multiplyByInverseOfAttitude:_referenceAttitude];
             } else {
             //NSLog(@"was nil : set new attitude", nil);
             _referenceAttitude = d.attitude;
             }
             
             float cRoll = -fabs(attitude.roll); // Up/Down en landscape
             float cYaw = attitude.yaw;  // Left/ Right en landscape -> pas besoin de prendre l'opposé
             float cPitch = attitude.pitch; // Depth en landscape -> pas besoin de prendre l'opposé
             //NSLog(@"roll: %.2f pitch: %.2f, yaw: %.2f, (x: %.2f, y: %.2f)", cRoll / ES_PI, cPitch / ES_PI, cYaw / ES_PI, _fingerRotationX / ES_PI, _fingerRotationY / ES_PI);
             
             UIDeviceOrientation orientation = [[UIDevice currentDevice] orientation];
             if (orientation == UIDeviceOrientationLandscapeRight ){
             cPitch = cPitch*-1; // correct depth when in landscape right
             }
             */
            
            _fMouseRollCorrection = -attitude.pitch;
            
            //Change the gravity correction to accelerometer correction .
            
            if (YES)
            {
                float fYaw, fPitch, fRoll;
                
                UIDeviceOrientation orientation = [[UIDevice currentDevice] orientation];
                
                switch(orientation)
                {
                    case UIDeviceOrientationLandscapeRight:
                    case UIDeviceOrientationLandscapeLeft:
                    case UIDeviceOrientationUnknown:
                    {
                        fYaw = attitude.yaw;
                        fPitch = attitude.roll + M_PI*0.5f;
                        fRoll = -attitude.pitch;
                        _bUpRight = false;
                    }
                        break;
                        
                    case UIDeviceOrientationPortrait:
                    case UIDeviceOrientationPortraitUpsideDown:
                    {
                        fYaw = attitude.yaw;
                        fPitch = -attitude.pitch;
                        fRoll = attitude.roll;
                        _bUpRight = true;
                    }
                        break;
                        
                    case UIDeviceOrientationFaceUp:
                    case UIDeviceOrientationFaceDown:
                    {
                        fYaw = attitude.yaw;
                        fPitch = attitude.roll + M_PI*0.5f;
                        fRoll = -attitude.pitch;
                    }
                        break;
                }
                
                // Reverse matrix multiplication .
                GLKMatrix4 matSensorsAndInput = GLKMatrix4Identity;
                
                if( _bUpRight )
                {
                    // Sensors .
                    GLKQuaternion qSensors = GLKQuaternionMake(d.attitude.quaternion.y, d.attitude.quaternion.x, d.attitude.quaternion.z, d.attitude.quaternion.w);
                    
                    GLKMatrix4 matSensors = GLKMatrix4MakeWithQuaternion(qSensors);
                    
                    //GLKQuaternion qPitchCorrection = GLKQuaternionMakeWithAngleAndAxis(M_PI_2, 1.0f, 0.0f, 0.0f);
                    
                    //qSensors =  GLKQuaternionMultiply(qSensors, qPitchCorrection);
                    
                    matSensors = GLKMatrix4RotateX(matSensors, M_PI_2);
                    
                    // Finger Input .
                    //GLKQuaternion qFingerYaw = GLKQuaternionMakeWithAngleAndAxis(_fingerRotationX, 0.0f, 1.0f, 0.0f);
                    
                    //GLKVector3 v3XAxiesRotated = GLKQuaternionRotateVector3(qFingerYaw, GLKVector3Make(1.0f, 0.0f, 0.0f));
                    
                    //GLKQuaternion qFingerPitch = GLKQuaternionMakeWithAngleAndAxis(_fingerRotationY, 1.0f/*v3XAxiesRotated.x*/, 0.0f/*v3XAxiesRotated.y*/, 0.0f/*v3XAxiesRotated.z*/);
                    
                    //GLKQuaternion qSandI = GLKQuaternionMultiply(qFingerYaw, qSensors);
                    
                    //qSandI = GLKQuaternionMultiply(qFingerPitch, qSandI);
                    
                    //GLKMatrix4 matInput = GLKMatrix4MakeWithQuaternion(qSandI);
                    
                    //GLKQuaternion qSensors = GLKQuaternionMakeWithMatrix4(matSensorsAndInput);
                    
                    //matSensorsAndInput = GLKMatrix4RotateX(matSensors, _fingerRotationX);
                    
                    //GLKVector3 v3YAxiesRotated = GLKMatrix4MultiplyVector3(matInput, GLKVector3Make(0.0f, 1.0f, 0.0f));
                    
                    matSensorsAndInput = GLKMatrix4RotateY(matSensors, _fingerRotationY);
                    
                    //matInput = GLKMatrix4RotateWithVector3(matInput, _fingerRotationY, v3YAxiesRotated);
                    
                    //matSensorsAndInput = GLKMatrix4Multiply(matSensors, matInput);
                    
                    //GLKQuaternion qSandI = GLKQuaternionMultiply(qSensors, qFingerPitch);
                    
                    //qSandI = GLKQuaternionMultiply(qSandI, qFingerYaw);
                    
                    //matSensorsAndInput = GLKMatrix4MakeWithQuaternion(qSandI);
                    
                    //matSensorsAndInput = GLKMatrix4Multiply(matSensors, matSensorsAndInput);
                    
                    //GLKQuaternion qYaw = GLKQuaternionMakeWithAngleAndAxis(fYaw, 0.0f, 1.0f, 0.0f);
                    //GLKQuaternion qPitch = GLKQuaternionMakeWithAngleAndAxis(fPitch, 1.0f, 0.0f, 0.0f);
                    //GLKQuaternion qRoll = GLKQuaternionMakeWithAngleAndAxis(fRoll, 0.0f, 0.0f, 1.0f);
                    
                    //GLKQuaternion qSensors = GLKQuaternionMultiply( qRoll, GLKQuaternionMultiply(qYaw, qPitch));
                    
                    // Finger Pitch .
                    //matSensorsAndInput = GLKMatrix4RotateX(matSensorsAndInput, -_fingerRotationY);
                    //GLKQuaternion qFingerPitch = GLKQuaternionMakeWithMatrix4(matSensorsAndInput);
                    
                    // Finger Yaw .
                    //matSensorsAndInput = GLKMatrix4RotateZ(matSensorsAndInput, _fingerRotationX);
                    //GLKQuaternion qFingerYaw = GLKQuaternionMakeWithMatrix4(GLKMatrix4RotateY(GLKMatrix4Identity, _fingerRotationY));
                    
                    //matSensorsAndInput = GLKMatrix4RotateX(matSensorsAndInput, ROLL_CORRECTION);
                    
                    //GLKQuaternion qSandI = GLKQuaternionMultiply( qPitch, GLKQuaternionMultiply(qSensorsAndInput, qYaw) );
                    
                    //matSensorsAndInput = GLKMatrix4MakeWithQuaternion(qSensors);
                }
                else
                {
                    // Pitch + Finger Pitch .
                    if( (fPitch + _fingerRotationX) >= M_PI_2 )
                        fPitch = M_PI_2;
                    else if( (fPitch + _fingerRotationX) <= -M_PI_2 )
                        fPitch = -M_PI_2;
                    else
                        fPitch = fPitch + _fingerRotationX;
                    
                    matSensorsAndInput = GLKMatrix4RotateX(matSensorsAndInput, fPitch);
                    //GLKQuaternion qPitch = GLKQuaternionMakeWithMatrix4(matSensorsAndInput);
                    //matSensorsAndInput = GLKMatrix4RotateX(matSensorsAndInput, v3Accel.x);
                    
                    // Yaw .
                    matSensorsAndInput = GLKMatrix4RotateY(matSensorsAndInput, fYaw);
                    //GLKQuaternion qYaw = GLKQuaternionMakeWithMatrix4(GLKMatrix4RotateY(GLKMatrix4Identity, _fingerRotationY));
                    //matSensorsAndInput = GLKMatrix4RotateY(matSensorsAndInput, v3Accel.y);
                    
                    // Roll .
                    
                    //if( (fRoll >= (-M_PI*0.15f)) && (fRoll < (M_PI*0.15f)) )
                    _fRoll = -attitude.pitch;
                    
                    matSensorsAndInput = GLKMatrix4RotateZ(matSensorsAndInput, _fRoll);
                    //GLKQuaternion qRoll = GLKQuaternionMakeWithMatrix4(GLKMatrix4RotateY(GLKMatrix4Identity, _fingerRotationY));
                    //matSensorsAndInput = GLKMatrix4RotateZ(matSensorsAndInput, v3Accel.z);
                    
                    // Finger Yaw .
                    matSensorsAndInput = GLKMatrix4RotateY(matSensorsAndInput, _fingerRotationY);
                }
                
                modelViewMatrix = GLKMatrix4Multiply(matSensorsAndInput, modelViewMatrix);
                
                //_savedGyroRotationX = cRoll + ROLL_CORRECTION + _fingerRotationX;
                //_savedGyroRotationY = cPitch + _fingerRotationY;
            }
        }
    }
    else
    {
        modelViewMatrix = GLKMatrix4RotateX(modelViewMatrix, _fingerRotationX);
        modelViewMatrix = GLKMatrix4RotateY(modelViewMatrix, _fingerRotationY);
    }
    
    _modelViewProjectionMatrix = GLKMatrix4Multiply(projectionMatrix, modelViewMatrix);
}

- (void)glkView:(GLKView *)view drawInRect:(CGRect)rect
{
    [_program use];
    
    glBindVertexArrayOES(_vertexArrayID);
    
    glUniformMatrix4fv(uniforms[UNIFORM_MODELVIEWPROJECTION_MATRIX], 1, 0, _modelViewProjectionMatrix.m);
    
    CVPixelBufferRef pixelBuffer = [self.videoPlayerController retrievePixelBufferToDraw];
    
    CVReturn err;
    if (pixelBuffer != NULL) {
        int frameWidth = (int)CVPixelBufferGetWidth(pixelBuffer);
        int frameHeight = (int)CVPixelBufferGetHeight(pixelBuffer);
        
        if (!_videoTextureCache) {
            NSLog(@"No video texture cache");
            CVPixelBufferRelease(pixelBuffer);
            return;
        }
        
        [self cleanUpTextures];
        
        // Y-plane
        glActiveTexture(GL_TEXTURE0);
        err = CVOpenGLESTextureCacheCreateTextureFromImage(kCFAllocatorDefault,
                                                           _videoTextureCache,
                                                           pixelBuffer,
                                                           NULL,
                                                           GL_TEXTURE_2D,
                                                           GL_RED_EXT,
                                                           frameWidth,
                                                           frameHeight,
                                                           GL_RED_EXT,
                                                           GL_UNSIGNED_BYTE,
                                                           0,
                                                           &_lumaTexture);
        if (err) {
            NSLog(@"Error at CVOpenGLESTextureCacheCreateTextureFromImage %d", err);
        }
        
        glBindTexture(CVOpenGLESTextureGetTarget(_lumaTexture), CVOpenGLESTextureGetName(_lumaTexture));
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
        glTexParameterf(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
        glTexParameterf(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
        
        // UV-plane.
        glActiveTexture(GL_TEXTURE1);
        err = CVOpenGLESTextureCacheCreateTextureFromImage(kCFAllocatorDefault,
                                                           _videoTextureCache,
                                                           pixelBuffer,
                                                           NULL,
                                                           GL_TEXTURE_2D,
                                                           GL_RG_EXT,
                                                           frameWidth / 2,
                                                           frameHeight / 2,
                                                           GL_RG_EXT,
                                                           GL_UNSIGNED_BYTE,
                                                           1,
                                                           &_chromaTexture);
        if (err) {
            NSLog(@"Error at CVOpenGLESTextureCacheCreateTextureFromImage %d", err);
        }
        
        glBindTexture(CVOpenGLESTextureGetTarget(_chromaTexture), CVOpenGLESTextureGetName(_chromaTexture));
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
        glTexParameterf(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
        glTexParameterf(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
        
        CVPixelBufferRelease(pixelBuffer);
        
        glClearColor(0.0f, 0.0f, 0.0f, 1.0f);
        glClear(GL_COLOR_BUFFER_BIT);
        
        glDrawElements ( GL_TRIANGLES, _numIndices,
                        GL_UNSIGNED_SHORT, 0 );
    }
    
    glBindVertexArrayOES(0);
    glUseProgram(0);
}

#pragma mark - OpenGL Program

- (void)buildProgram {
    _program = [[GLProgram alloc]
                initWithVertexShaderFilename:@"Shader"
                fragmentShaderFilename:@"Shader"];
    
    [_program addAttribute:@"position"];
    [_program addAttribute:@"texCoord"];
    
    if (![_program link]) {
        NSString *programLog = [_program programLog];
        NSLog(@"Program link log: %@", programLog);
        NSString *fragmentLog = [_program fragmentShaderLog];
        NSLog(@"Fragment shader compile log: %@", fragmentLog);
        NSString *vertexLog = [_program vertexShaderLog];
        NSLog(@"Vertex shader compile log: %@", vertexLog);
        _program = nil;
        NSAssert(NO, @"Falied to link HalfSpherical shaders");
    }
    
    _vertexTexCoordAttributeIndex = [_program attributeIndex:@"texCoord"];
    
    uniforms[UNIFORM_MODELVIEWPROJECTION_MATRIX] = [_program uniformIndex:@"modelViewProjectionMatrix"];
    uniforms[UNIFORM_Y] = [_program uniformIndex:@"SamplerY"];
    uniforms[UNIFORM_UV] = [_program uniformIndex:@"SamplerUV"];
    uniforms[UNIFORM_COLOR_CONVERSION_MATRIX] = [_program uniformIndex:@"colorConversionMatrix"];
}

#pragma mark - touches

- (void)touchesBegan:(NSSet *)touches withEvent:(UIEvent *)event
{
    //if(_isUsingMotion) return;
    for (UITouch *touch in touches) {
        [_currentTouches addObject:touch];
    }
}

- (void)touchesMoved:(NSSet *)touches withEvent:(UIEvent *)event
{
    //if(_isUsingMotion) return;
    UITouch *touch = [touches anyObject];
    float distX = [touch locationInView:touch.view].x -
    [touch previousLocationInView:touch.view].x;
    float distY = [touch locationInView:touch.view].y -
    [touch previousLocationInView:touch.view].y;
    distX *= -0.005;
    distY *= -0.005;
    
    float fDX = distY * _overture / 100;
    float fDY = distX * _overture / 100;
    
    float fDRotationX = (fDX*cosf(_fMouseRollCorrection) + fDY*sinf(_fMouseRollCorrection));
    float fDRotationY = (-fDX*sinf(_fMouseRollCorrection) + fDY*cosf(_fMouseRollCorrection));
    
    if( ((_fingerRotationX + fDRotationX) < M_PI_2) && ((_fingerRotationX + fDRotationX) > -M_PI_2) )
        _fingerRotationX += fDRotationX;
    
    //if( ((_fingerRotationY - fDRotationY) < M_PI_2) && ((_fingerRotationY - fDRotationY) > -M_PI_2) )
    _fingerRotationY -= fDRotationY;
    
    //_fingerRotationX += fDX;
    //_fingerRotationY += fDY;
}

- (void)touchesEnded:(NSSet *)touches withEvent:(UIEvent *)event {
    if (_isUsingMotion) return;
    for (UITouch *touch in touches) {
        [_currentTouches removeObject:touch];
    }
}
- (void)touchesCancelled:(NSSet *)touches withEvent:(UIEvent *)event {
    for (UITouch *touch in touches) {
        [_currentTouches removeObject:touch];
    }
}

- (void)handlePinchGesture:(UIPinchGestureRecognizer *)recognizer {
    _overture /= recognizer.scale;
    
    if (_overture > MAX_OVERTURE)
        _overture = MAX_OVERTURE;
    if(_overture<MIN_OVERTURE)
        _overture = MIN_OVERTURE;
}
@end
