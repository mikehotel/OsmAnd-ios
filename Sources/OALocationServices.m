//
//  OALocationServices.m
//  OsmAnd
//
//  Created by Alexey Pelykh on 2/25/14.
//  Copyright (c) 2014 OsmAnd. All rights reserved.
//

#import "OALocationServices.h"

#import <UIKit/UIKit.h>

#import "OsmAndApp.h"
#import "OAAutoObserverProxy.h"

@interface OALocationServices () <CLLocationManagerDelegate>
@end

@implementation OALocationServices
{
    OsmAndAppInstance _app;
    
    CLLocationManager* _manager;
    BOOL _locationActive;
    BOOL _compassActive;
    
    OAAutoObserverProxy* _mapModeObserver;
    
    BOOL _waitingForAuthorization;
    
    CLLocation* _lastLocation;
    CLLocationDirection _lastHeading;
}

- (id)initWith:(OsmAndAppInstance)app
{
    self = [super init];
    if (self) {
        [self ctor:app];
    }
    return self;
}

- (void)dealloc
{
    [self dtor];
}

- (void)ctor:(OsmAndAppInstance)app
{
    _app = app;
    
    _locationActive = NO;
    _compassActive = NO;
    _statusObservable = [[OAObservable alloc] init];
    
    _stateObservable = [[OAObservable alloc] init];
    
    _manager = [[CLLocationManager alloc] init];
    _manager.delegate = self;
    _manager.distanceFilter = kCLDistanceFilterNone;
    _manager.pausesLocationUpdatesAutomatically = NO;
    
    _mapModeObserver = [[OAAutoObserverProxy alloc] initWith:self withHandler:@selector(onMapModeChanged)];
    [_mapModeObserver observe:_app.mapModeObservable];
    
    _waitingForAuthorization = NO;
    
    _lastLocation = nil;
    _lastHeading = NAN;
    _updateObserver = [[OAObservable alloc] init];
}

- (void)dtor
{
}

- (BOOL)available
{
    return [CLLocationManager locationServicesEnabled];
}

- (BOOL)compassPresent
{
    return [CLLocationManager headingAvailable];
}

- (BOOL)allowed
{
    return ([CLLocationManager authorizationStatus] == kCLAuthorizationStatusAuthorized);
}

- (BOOL)denied
{
    return ([CLLocationManager authorizationStatus] == kCLAuthorizationStatusDenied);
}

@synthesize stateObservable = _stateObservable;

- (OALocationServicesStatus)status
{
    if(_waitingForAuthorization)
        return OALocationServicesStatusAuthorizing;
    return (_locationActive || _compassActive) ? OALocationServicesStatusActive : OALocationServicesStatusInactive;
}

@synthesize statusObservable = _statusObservable;

- (void)start
{
    // Do nothing if waiting for authorization
    if(self.status == OALocationServicesStatusAuthorizing)
        return;
    
    BOOL didChange = NO;

    // Listen to device orientation change
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(deviceOrientationDidChange)
                                                 name:UIDeviceOrientationDidChangeNotification
                                               object:nil];
    
    // Set current device orientation
    [self updateDeviceOrientation];
    
    //TODO: use different accuracy modes
    // kCLLocationAccuracyBestForNavigation (when plugged in) && kCLLocationAccuracyBest - during navigation
    
    // Set desired accuracy depending on app mode, and query for updates
    if(!_locationActive)
    {
        _waitingForAuthorization = !self.allowed;
        
        _manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters;
        [_manager startUpdatingLocation];
        _locationActive = YES;
        didChange = YES;
    }
    
    // Also, if compass is available, query it for updates
    if(!_compassActive && [CLLocationManager headingAvailable])
    {
       [_manager startUpdatingHeading];
        _compassActive = YES;
        didChange = YES;
    }
    
    if(didChange)
        [_statusObservable notifyEvent];
}

- (void)stop
{
    BOOL didChange = NO;
    
    if(_waitingForAuthorization)
    {
        _waitingForAuthorization = NO;
        didChange = YES;
    }
    
    if(_locationActive)
    {
        [_manager stopUpdatingLocation];
        _locationActive = NO;
        didChange = YES;
    }
    
    if(_compassActive)
    {
        [_manager stopUpdatingHeading];
        _compassActive = NO;
        didChange = YES;
    }
    
    [[NSNotificationCenter defaultCenter] removeObserver:self
                                                    name:UIDeviceOrientationDidChangeNotification
                                                  object:nil];
    
    if(didChange)
       [_statusObservable notifyEvent];
    
    // If location services are stopped, set free mode for map, since to location data available
    _app.mapMode = OAMapModeFree;
}

- (void)locationManager:(CLLocationManager *)manager didChangeAuthorizationStatus:(CLAuthorizationStatus)status
{
    // If services were running, but now authorization was revoked, stop them
    if(status != kCLAuthorizationStatusAuthorized && status != kCLAuthorizationStatusNotDetermined && (_locationActive || _compassActive))
        [self stop];
    
    [_stateObservable notifyEvent];
}

- (void)locationManager:(CLLocationManager *)manager didFailWithError:(NSError *)error
{
    if(error.domain == kCLErrorDomain && error.code == kCLErrorDenied)
    {
        // User have denied services or revoked authorization, stop the services
        // If services were running, but now authorization was revoked, stop them
        if(_locationActive || _compassActive)
            [self stop];
        return;
    }
    
    NSLog(@"CLLocationManager didFailWithError %@", error);
}

- (CLLocation*)lastKnownLocation
{
    if(_lastLocation != nil)
        return _lastLocation;
    return _manager.location;
}

- (CLLocationDirection)lastKnownHeading
{
    if(!isnan(_lastHeading))
        return _lastHeading;
    return _manager.heading.trueHeading;
}

@synthesize updateObserver = _updateObserver;

- (void)locationManager:(CLLocationManager *)manager didUpdateLocations:(NSArray *)locations
{
    // If was waiting for authorization, now it's granted
    if(_waitingForAuthorization)
    {
        [_statusObservable notifyEvent];
        _waitingForAuthorization = NO;
    }
    
    _lastLocation = [locations lastObject];
    [_updateObserver notifyEvent];
}

- (void)locationManager:(CLLocationManager *)manager didUpdateHeading:(CLHeading *)newHeading
{
    // If was waiting for authorization, now it's granted
    if(_waitingForAuthorization)
    {
        [_statusObservable notifyEvent];
        _waitingForAuthorization = NO;
    }
    
    _lastHeading = newHeading.trueHeading;
    [_updateObserver notifyEvent];
}

- (void)onMapModeChanged
{
    if(_app.mapMode == OAMapModeFree)
    {
        //TODO: if running, reduce accuracy to near-10-meter?
        return;
    }
    
    // If mode is OAMapModePositionTrack or OAMapModeFollow, and services are not running,
    // launch them (except if waiting for user authorization).
    OALocationServicesStatus status = self.status;
    if(status == OALocationServicesStatusActive || status == OALocationServicesStatusAuthorizing)
        return;
    [self start];
}

- (void)deviceOrientationDidChange
{
    [self updateDeviceOrientation];
}

- (void)updateDeviceOrientation
{
    const UIDeviceOrientation uiDeviceOrientation = [UIDevice currentDevice].orientation;
    CLDeviceOrientation clDeviceOrientation;
    switch (uiDeviceOrientation)
    {
        case UIDeviceOrientationPortrait:
            clDeviceOrientation = CLDeviceOrientationPortrait;
            break;
        case UIDeviceOrientationPortraitUpsideDown:
            clDeviceOrientation = CLDeviceOrientationPortraitUpsideDown;
            break;
        case UIDeviceOrientationLandscapeLeft:
            clDeviceOrientation = CLDeviceOrientationLandscapeLeft;
            break;
        case UIDeviceOrientationLandscapeRight:
            clDeviceOrientation = CLDeviceOrientationLandscapeRight;
            break;
        case UIDeviceOrientationFaceUp:
            clDeviceOrientation = CLDeviceOrientationFaceUp;
            break;
        case UIDeviceOrientationFaceDown:
            clDeviceOrientation = CLDeviceOrientationFaceDown;
            break;

        case UIDeviceOrientationUnknown:
        default:
            clDeviceOrientation = CLDeviceOrientationUnknown;
            break;
    }
    _manager.headingOrientation = clDeviceOrientation;
}

+ (void)showDeniedAlert
{
    UIAlertView *alertView = [[UIAlertView alloc] initWithTitle:@"title"
                                                        message:@"msg"
                                                       delegate:nil
                                              cancelButtonTitle:@"ok"
                                              otherButtonTitles:nil];
    [alertView show];
}

@end
