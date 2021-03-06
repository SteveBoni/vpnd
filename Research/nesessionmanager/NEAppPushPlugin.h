//
//     Generated by classdumpios 1.0.1 (64 bit) (iOS port by DreamDevLost)(Debug version compiled Sep 26 2020 13:48:20).
//
//  Copyright (C) 1997-2019 Steve Nygard.
//

#import "NEPlugin.h"

#import "NEAppPushPluginManager-Protocol.h"

@interface NEAppPushPlugin : NEPlugin <NEAppPushPluginManager>
{
}

- (void)handleProviderStopped;	// IMP=0x000000010001608c
- (void)sendExtensionFailed;	// IMP=0x0000000100015fc4
- (void)reportIncomingCall:(id)arg1;	// IMP=0x0000000100015ec4
- (void)handleProviderError:(id)arg1 forMessageID:(id)arg2;	// IMP=0x0000000100015d90
- (void)handleProviderError:(id)arg1;	// IMP=0x0000000100015c90
- (id)managerInterface;	// IMP=0x0000000100015c74
- (id)remotePluginInterface;	// IMP=0x0000000100015c58
- (void)sendTimerEvent;	// IMP=0x0000000100015c18
- (void)sendOutgoingCallMessage:(id)arg1 andMessageID:(id)arg2;	// IMP=0x0000000100015b90
- (void)setProviderConfiguration:(id)arg1;	// IMP=0x0000000100015b24
- (void)stopWithReason:(int)arg1;	// IMP=0x0000000100015adc
- (void)startConnectionWithProviderConfig:(id)arg1;	// IMP=0x0000000100015a70

@end

