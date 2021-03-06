//
//     Generated by classdumpios 1.0.1 (64 bit) (iOS port by DreamDevLost)(Debug version compiled Sep 26 2020 00:23:19).
//
//  Copyright (C) 1997-2019 Steve Nygard.
//

#import <objc/NSObject.h>

@class ACAccountStore;

@interface TVSettingsUserProfilesValidator : NSObject
{
    long long _userActionType;	// 8 = 0x8
    ACAccountStore *_accountStore;	// 16 = 0x10
}

+ (id)_userProfiles;	// IMP=0x00000001000e66bc
- (void).cxx_destruct;	// IMP=0x00000001000e6758
@property(readonly, nonatomic) ACAccountStore *accountStore; // @synthesize accountStore=_accountStore;
@property(nonatomic) long long userActionType; // @synthesize userActionType=_userActionType;
- (_Bool)_canSignInWithiCloudAltDSID:(id)arg1 gameCenterAltDSID:(id)arg2 error:(id *)arg3;	// IMP=0x00000001000e5de0
- (_Bool)canSignInUserWithGameCenterAltDSID:(id)arg1 error:(id *)arg2;	// IMP=0x00000001000e5dc8
- (_Bool)canSignInUserWithiCloudAltDSID:(id)arg1 error:(id *)arg2;	// IMP=0x00000001000e5db4
- (_Bool)canAddUserWithiCloudAltDSID:(id)arg1 gameCenterAltDSID:(id)arg2 error:(id *)arg3;	// IMP=0x00000001000e5d50
- (_Bool)canAddUserWithAltDSID:(id)arg1 error:(id *)arg2;	// IMP=0x00000001000e5d3c
- (id)init;	// IMP=0x00000001000e5cd8

@end

