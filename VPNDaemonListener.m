
#import "VPNDaemonListener.h"
#import "VPNApplicationProtocol.h"
#import <notify.h>

#import <objc/runtime.h>
#import <UIKit/UIImage.h>
#define APPLICATION_IDENTIFIER "com.nito.vpnd"

/**
 
 USE_PROFILE attempts to use the full profile rather than cherry picking a few choice pieces of data out of the config profile. that code is very experimental /
 tempermental and unreliable, especially if you've already created a VPN connection. tread carefully!

 */

//#define USE_PROFILE 1

///////////////////////////////////////////////////////////////////////////
// Private API
///////////////////////////////////////////////////////////////////////////

@interface NSDistributedNotificationCenter : NSNotificationCenter

+ (id)defaultCenter;

- (void)addObserver:(id)arg1 selector:(SEL)arg2 name:(id)arg3 object:(id)arg4;
- (void)postNotificationName:(id)arg1 object:(id)arg2 userInfo:(id)arg3;

@end

@interface NEVPNManager (bruh)
- (void)setConfiguration:(id)sender;
- (NEConfiguration *)configuration;
@end

///////////////////////////////////////////////////////////////////////////
// Main daemon class
///////////////////////////////////////////////////////////////////////////

@interface VPNDaemonListener ()
    
@property (nonatomic, strong) NSDictionary *settings;
@property (nonatomic, strong) NSXPCConnection* xpcConnection;
@property (readwrite, assign) NSInteger interfaceStyle; //UIUserInterfaceStyle
@property (nonatomic, strong) NEConfiguration *configuration;
@property (nonatomic, strong) id configurationProfile;

//@property NEVPNManager *vpnManager;
//DONT DO THIS ^^

@end

@implementation VPNDaemonListener

#pragma mark •• VPN code

- (void)toggleVPN {
    NEVPNStatus status = [VPNDaemonListener currentVPNStatusWithRefresh:true];
      if (status == NEVPNStatusConnected){
          [self stopVPNTunnel];
      } else {
          [self applicationStartVPNConnection:nil];
      }
    
}

+ (NEVPNProtocolIKEv2 *)prepareIKEv2ParametersForServer:(NSString *)server
                                            eapUsername:(NSString *)user
                                         eapPasswordRef:(NSData *)passRef
                                    withCertificateType:(NEVPNIKEv2CertificateType)certType
                                            blacklistJS:(NSString *)blacklistJavascriptString {
    
    NEVPNProtocolIKEv2 *protocolConfig = [[NEVPNProtocolIKEv2 alloc] init];
    [protocolConfig setServerAddress:server];
    [protocolConfig setServerCertificateCommonName:server];
    [protocolConfig setRemoteIdentifier:server];
    [protocolConfig setEnablePFS:YES];
    [protocolConfig setDisableMOBIKE:NO];
    [protocolConfig setDisconnectOnSleep:NO];
    [protocolConfig setAuthenticationMethod:NEVPNIKEAuthenticationMethodCertificate]; // to validate the server-side cert issued by LetsEncrypt
    [protocolConfig setCertificateType:certType];
    [protocolConfig setUseExtendedAuthentication:YES];
    [protocolConfig setUsername:user];
    [protocolConfig setPasswordReference:passRef];
    [protocolConfig setDeadPeerDetectionRate: NEVPNIKEv2DeadPeerDetectionRateLow];
    
    NEProxySettings *proxSettings = [[NEProxySettings alloc] init];
    [proxSettings setAutoProxyConfigurationEnabled:YES];
    if (blacklistJavascriptString != nil){ //only add these changes if the blacklist has any enabled items.
        [proxSettings setProxyAutoConfigurationJavaScript: blacklistJavascriptString];
        //NSLog(@"[vpnd] proxyAutoConfigurationJavaScript %@", [proxSettings proxyAutoConfigurationJavaScript]);
        [protocolConfig setProxySettings:proxSettings];
    }
    [[protocolConfig IKESecurityAssociationParameters] setEncryptionAlgorithm:NEVPNIKEv2EncryptionAlgorithmAES256];
    [[protocolConfig IKESecurityAssociationParameters] setIntegrityAlgorithm:NEVPNIKEv2IntegrityAlgorithmSHA384];
    [[protocolConfig IKESecurityAssociationParameters] setDiffieHellmanGroup:NEVPNIKEv2DiffieHellmanGroup20];
    [[protocolConfig IKESecurityAssociationParameters] setLifetimeMinutes:59];
    [[protocolConfig childSecurityAssociationParameters] setEncryptionAlgorithm:NEVPNIKEv2EncryptionAlgorithmAES256GCM];
    [[protocolConfig childSecurityAssociationParameters] setDiffieHellmanGroup:NEVPNIKEv2DiffieHellmanGroup20];
    [[protocolConfig childSecurityAssociationParameters] setLifetimeMinutes:20]; 
    return protocolConfig;
}

+(NEVPNManager *)currentVPNManager {
   return [NEVPNManager sharedManager];
}

+ (NEVPNStatus)currentVPNStatusWithRefresh:(BOOL)refresh {
    NEVPNManager *vpnManager = [VPNDaemonListener currentVPNManager];
    __block NEVPNStatus status = [[vpnManager connection] status];
    if (refresh){
        [vpnManager loadFromPreferencesWithCompletionHandler:^(NSError * _Nullable error) {
           
            status = [(NEVPNConnection *)[vpnManager connection] status];
            
        }];
        return status;
    } else {
        return status;
    }
    return status;
}

- (void)stopVPNTunnel {
    NEVPNManager *vpnManager = [VPNDaemonListener currentVPNManager];
    [vpnManager setEnabled:NO];
    [vpnManager saveToPreferencesWithCompletionHandler:^(NSError *saveErr) {
           if (saveErr) {
               NSLog(@"[DEBUG][disconnectVPN] error saving update for firewall config = %@", saveErr);
               [(NEVPNConnection*)[vpnManager connection] stopVPNTunnel];
           } else {
               [(NEVPNConnection*)[vpnManager connection] stopVPNTunnel];
           }
       }];
}

+ (NSArray *)vpnOnDemandRules {
    // RULE: do not take action if certain types of inflight wifi, needed because they do not detect captive portal properly
    NEOnDemandRuleIgnore *onboardIgnoreRule = [[NEOnDemandRuleIgnore alloc] init];
    [onboardIgnoreRule setInterfaceTypeMatch:NEOnDemandRuleInterfaceTypeWiFi];
    [onboardIgnoreRule setSSIDMatch:@[@"gogoinflight", @"AA Inflight", @"AA-Inflight"]];
    
    // RULE: disconnect if 'xfinitywifi' as they apparently block IPSec traffic (???)
    NEOnDemandRuleDisconnect *xfinityDisconnect = [[NEOnDemandRuleDisconnect alloc] init];
    [xfinityDisconnect setInterfaceTypeMatch:NEOnDemandRuleInterfaceTypeWiFi];
    [xfinityDisconnect setSSIDMatch:@[@"xfinitywifi"]];
    
    // RULE: connect to VPN automatically if server reports that it is running OK
    NEOnDemandRuleConnect *vpnServerConnectRule = [[NEOnDemandRuleConnect alloc] init];
    [vpnServerConnectRule setInterfaceTypeMatch:NEOnDemandRuleInterfaceTypeAny];
    [vpnServerConnectRule setProbeURL:[NSURL URLWithString:[NSString stringWithFormat:@"https://%@%@", [[NSUserDefaults standardUserDefaults] objectForKey:kGRDHostnameOverride], kSGAPI_ServerStatus]]];
    
    NSArray *onDemandArr = @[onboardIgnoreRule, xfinityDisconnect, vpnServerConnectRule];
    return onDemandArr;
}
    
- (void)reloadSettings {
    // Reload settings.
    NSLog(@"*** [vpnd] :: Reloading settings");
    
    CFPreferencesAppSynchronize(CFSTR(APPLICATION_IDENTIFIER));
    
    CFArrayRef keyList = CFPreferencesCopyKeyList(CFSTR(APPLICATION_IDENTIFIER), kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
    
    if (!keyList) {
        self.settings = [NSMutableDictionary dictionary];
    } else {
        CFDictionaryRef dictionary = CFPreferencesCopyMultiple(keyList, CFSTR(APPLICATION_IDENTIFIER), kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
        
        self.settings = [(__bridge NSDictionary *)dictionary copy];
        
        CFRelease(dictionary);
        CFRelease(keyList);
    }
}

- (void)setPreferenceKey:(NSString*)key withValue:(id)value {
    if (!key || !value) {
        NSLog(@"*** [vpnd] :: Not setting value, as one of the arguments is null");
        return;
    }
    
    NSMutableDictionary *mutableSettings = [self.settings mutableCopy];
    
    [mutableSettings setObject:value forKey:key];
    
    // Write to CFPreferences
    CFPreferencesSetValue ((__bridge CFStringRef)key, (__bridge CFPropertyListRef)value, CFSTR(APPLICATION_IDENTIFIER), kCFPreferencesCurrentUser, kCFPreferencesCurrentHost);
    
    self.settings = mutableSettings;
    
    // Sync
    CFPreferencesAppSynchronize(CFSTR(APPLICATION_IDENTIFIER));
}

- (id)getPreferenceKey:(NSString*)key {
    return [self.settings objectForKey:key];
}
    
- (void)initialiseListener {
    
    [self reloadSettings];
    
}


- (void)applicationStopVPNConnection {
    NEVPNManager *vpnManager = [VPNDaemonListener currentVPNManager];
    [vpnManager setEnabled:NO];
    [vpnManager saveToPreferencesWithCompletionHandler:^(NSError *saveErr) {
           if (saveErr) {
               NSLog(@"[DEBUG][disconnectVPN] error saving update for firewall config = %@", saveErr);
               [(NEVPNConnection*)[vpnManager connection] stopVPNTunnel];
           } else {
               [(NEVPNConnection*)[vpnManager connection] stopVPNTunnel];
           }
       }];
}

- (BOOL)darkMode {
    if (@available(tvOS 10.0, *)) {
        if (self.interfaceStyle == UIUserInterfaceStyleDark) return true;
    }
    return false;
}


- (void)showBulletinWithTitle:(NSString *)title message:(NSString *)message timeout:(NSInteger)timeout {
    NSMutableDictionary *dict = [NSMutableDictionary new];
    dict[@"message"] = message;
    dict[@"title"] = title;
    dict[@"timeout"] = [NSNumber numberWithInteger:timeout];
    NSString *imageName = @"/var/mobile/Images/front_minimal.png";
    if ([self darkMode]){
        imageName = @"/var/mobile/Images/front-dark-minimal.png";
    }
    UIImage *image = [UIImage imageWithContentsOfFile:imageName];
    NSData *imageData = UIImagePNGRepresentation(image);;
    if (imageData){
        dict[@"imageData"] = imageData;
    }
    [[NSDistributedNotificationCenter defaultCenter] postNotificationName:@"com.nito.bulletinh4x/displayBulletin" object:nil userInfo:dict];
    
}


- (void)handleConnectionStatus:(NEVPNStatus)status {
    NSLog(@"[vpnd] handleConnectionStatus: %li", (long)status);
    switch (status) {
        case NEVPNStatusConnected:{
            [[self.xpcConnection remoteObjectProxy] daemonReportsStatus:status];
            [self showBulletinWithTitle:@"VPN" message:@"Connection established." timeout:2];
            [[NSDistributedNotificationCenter defaultCenter]postNotificationName:@"com.nito.vpnd/connected" object:nil];
            break;
        }
        case NEVPNStatusDisconnected:{
            [self showBulletinWithTitle:@"VPN" message:@"Disconnected." timeout:2];
            [[NSDistributedNotificationCenter defaultCenter]postNotificationName:@"com.nito.vpnd/discconnected" object:nil];
        case NEVPNStatusInvalid:
            [[self.xpcConnection remoteObjectProxy] daemonReportsStatus:status];
            break;
        }
            /*
            
        case NEVPNStatusDisconnecting:
            [self showBulletinWithTitle:@"VPN" message:@"Disconnecting..." timeout:2];
            break;
            
        case NEVPNStatusConnecting:
            [self showBulletinWithTitle:@"VPN" message:@"Connecting..." timeout:2];
        case NEVPNStatusReasserting:
            [self showBulletinWithTitle:@"VPN" message:@"Reasserting..." timeout:2];
            break;
            */
        default:
            break;
        }
}

//this tracks whether we are in light or dark mode, since we have no UI we "need" the application to report this data to us
- (void)applicationChangedViewMode:(NSInteger)style{
    
    NSLog(@"*** [vpnd] :: applicationChangedViewMode: %lu", style);
    self.interfaceStyle = style;
}

//easy way to get access to our 'application name' since we are in a daemon this is normally blank unless we force set it (set below)
- (NSString *)configApplicationName {
    return [[[VPNDaemonListener currentVPNManager] configuration] applicationName];
}

/**
 
 One of the core VPN functions, this receives a payload from a VPN configuration dictionary that is part of the mobile config file.

 in the default, stable and reliable mode we only pluck out three pieces of information to get things working, the username, password and server name.
 user name and password are stored in the keychain and the server is stored in NSUserDefaults, upon toggling again with 'nil' paramater we
 will just assume they are turning it on again and to load with those saved settings instead of trying to process a new profile
 
 in the USE_PROFILE mode it attempts to create a new NEConfiguration & configurationProfile to set instead of NEVPNProtocolIKEv2 that is created
 above.
 
 
 */

- (void)applicationStartVPNConnection:(NSDictionary *)mainPayload {
    NSLog(@"*** [vpnd] :: applicationStartVPNConnection:");
    #ifndef USE_PROFILE
    __block NSString *eapUsername = nil;
    __block NSString *vpnServer = nil;
    __block NSString *blacklistJS = nil;
    __block NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    #else
    //__block id cp = nil;
    //__block id config = nil;
    #endif
    NEVPNManager *vpnManager = [VPNDaemonListener currentVPNManager];
    //if you arent familiar with NEVPNManager calling one of these to an active VPN setup is required at least once per run.
    [vpnManager loadFromPreferencesWithCompletionHandler:^(NSError * _Nullable error) {
        
        if (error){
            NSLog(@"[vpnd] Load error: %@", error);
        } else {
            
            if (mainPayload){
                NSLog(@"[vpnd] mainPayload: %@", mainPayload);
                NSString *payloadType = mainPayload[@"PayloadType"];
                if ([payloadType isEqualToString:@"com.apple.vpn.managed"]){
                    
                    NSLog(@"[vpnd] we got a VPN dealy!");
                    #ifdef USE_PROFILE
                    
                    //EXPERIMENTAL!! BUYER BEWARE!
                    
                    [vpnManager setProtocolConfiguration:nil];
                    NSString *payloadDisplayName = mainPayload[@"PayloadDisplayName"];
                    
                    //MCVPNPayloadBase is in ManagedConfiguration framework the goal is to make ourselves an NEConfiguration and
                    //then to create a 'configurationProtocol' from there. this works the first time but then struggles to work subsequent times
                    id mcPayloadBase = [NSClassFromString(@"MCVPNPayloadBase") NEVPNPayloadBaseDelegateWithConfigurationDict:mainPayload];
                    NSLog(@"mcPayloadBase: %@", mcPayloadBase);
                    self.configuration = [[NSClassFromString(@"NEConfiguration") alloc] initWithVPNPayload:mcPayloadBase configurationName: payloadDisplayName grade: 1];
                    NSLog(@"[vpnd] config : %@ made with name: %@", self.configuration, payloadDisplayName);
                    [vpnManager setConfiguration:self.configuration];
                    [self.configuration syncWithSystemKeychain]; //maybe this is wrong because we are owned by mobile and not root?
                    self.configurationProfile = [self.configuration getConfigurationProtocol];
                    NSLog(@"[vpnd] config protocol: %@", self.configurationProfile);
                    [vpnManager setProtocolConfiguration:self.configurationProfile];
                
                    #else
                    
                    //loading from just username, password and server address
                    
                    NSDate *expiration = mainPayload[kMCPayloadExpirationDate];
                    NSLog(@"*** [vpnd] :: ExpirationDate: %@", expiration);
                    [defaults setValue:expiration forKey:kMCPayloadExpirationDate];
                    NSDictionary *iKEv2 = mainPayload[@"IKEv2"];
                    eapUsername = iKEv2[@"AuthName"];
                    NSString *pw = iKEv2[@"AuthPassword"];
                    vpnServer = iKEv2[@"RemoteAddress"];
                    blacklistJS = mainPayload[@"JSBlacklist"];
                    [defaults setValue:eapUsername forKey:kKeychainStr_EapUsername];
                    [defaults setValue:blacklistJS forKey:@"blacklistJS"];
                    [defaults setValue:vpnServer forKey:kGRDHostnameOverride];
                    [VPNDaemonListener storePassword:eapUsername forAccount:kKeychainStr_EapUsername];
                    [VPNDaemonListener storePassword:pw forAccount:kKeychainStr_EapPassword];
                    #endif
                }
            } else { //no main payload, load from previous session
                #ifndef USE_PROFILE
                eapUsername = [VPNDaemonListener getPasswordStringForAccount:kKeychainStr_EapUsername];
                vpnServer = [defaults valueForKey:kGRDHostnameOverride];
                blacklistJS = [defaults valueForKey:@"blacklistJS"];
                #endif
            }
            
            #ifndef USE_PROFILE
            NSData *eapPassword = [VPNDaemonListener getPasswordRefForAccount:kKeychainStr_EapPassword];
            [vpnManager setProtocolConfiguration:[VPNDaemonListener prepareIKEv2ParametersForServer:vpnServer eapUsername:eapUsername eapPasswordRef:eapPassword withCertificateType:NEVPNIKEv2CertificateTypeECDSA256 blacklistJS:blacklistJS]];
            [vpnManager setOnDemandEnabled:true];
            [vpnManager setLocalizedDescription:@"Guardian Firewall"];
            [vpnManager setOnDemandRules:[VPNDaemonListener vpnOnDemandRules]];
            #else
            if (self.configuration && self.configurationProfile){
                [vpnManager setConfiguration:self.configuration];
                [vpnManager setProtocolConfiguration:self.configurationProfile];
            }
            #endif
            [vpnManager setEnabled: YES];
                      
            NSLog(@"protocolConfig: %@", [vpnManager protocolConfiguration]);
            NEConfiguration *nec = [[VPNDaemonListener currentVPNManager] configuration];
            [nec setApplication:@"com.nito.nitoTV4"];
            [nec setApplicationName:@"nitoTV"];
        
            [vpnManager saveToPreferencesWithCompletionHandler:^(NSError * _Nullable error) {
                NSLog(@"[vpnd] save with error: %@", error);
                if (error){
                    [vpnManager saveToPreferencesWithCompletionHandler:^(NSError * _Nullable error) {
                        NSError *error2 = nil;
                        [[vpnManager connection] startVPNTunnelAndReturnError: &error2];
                        NSLog(@"[vpnd] error: %@", error);
                    }];
                } else {
                    NSError *error2 = nil;
                    [[vpnManager connection] startVPNTunnelAndReturnError: &error2];
                    NSLog(@"[vpnd] error: %@", error);
                }
            }];
        }
    }];

}

//this gets called when the control center widget requests our current connectivity status
- (void)CCRequestVPNStatus:(NSNotification *)n {
    
    NSLog(@"*** [vpnd] :: CCRequestVPNStatus");
    switch ([[[VPNDaemonListener currentVPNManager] connection] status]) {
        case NEVPNStatusConnected:
            [[NSDistributedNotificationCenter defaultCenter]postNotificationName:@"com.nito.vpnd/connected" object:nil];
            break;
        case NEVPNStatusDisconnected:
            [[NSDistributedNotificationCenter defaultCenter]postNotificationName:@"com.nito.vpnd/disconnected" object:nil];
            break;
        default:
            break;
    }
}

//monitors the VPN connection status to show the bulletins (user notifications) when the state changes between connected / disconnected
- (void)monitorVPNConnection {
    
    NSLog(@"*** [vpnd] :: monitorVPNConnection");
    [[NSDistributedNotificationCenter defaultCenter]addObserver:self selector:@selector(CCRequestVPNStatus:) name:@"com.nito.vpnd/request-status" object:nil];
    
    [[NSNotificationCenter defaultCenter] addObserverForName:NEVPNStatusDidChangeNotification object:nil queue:nil usingBlock:^(NSNotification *notif) {
        id object = [notif object];
        [self handleConnectionStatus:[(NEVPNConnection *)object status]];
    }];
}

#pragma mark •• Keychain code

+ (NSData *)getPasswordRefForAccount:(NSString *)accountKeyStr {
    NSString *bundleId = [NSString stringWithUTF8String:APPLICATION_IDENTIFIER];
    CFTypeRef copyResult = NULL;
    NSDictionary *query = @{
        (__bridge id)kSecClass : (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService : bundleId,
        (__bridge id)kSecAttrAccount : accountKeyStr,
        (__bridge id)kSecMatchLimit : (__bridge id)kSecMatchLimitOne,
        (__bridge id)kSecReturnPersistentRef : (__bridge id)kCFBooleanTrue,
        (__bridge id)kSecAttrAccessGroup: bundleId,
    };
    OSStatus results = SecItemCopyMatching((__bridge CFDictionaryRef)query, (CFTypeRef *)&copyResult);
    if (results != errSecSuccess) {
        NSLog(@"[vpnd] error obtaining password ref: %ld", (long)results);
    }
    
    return (__bridge NSData *)copyResult;
}

+ (NSString *)getPasswordStringForAccount:(NSString *)accountKeyStr {
    CFTypeRef copyResult = NULL;
    NSString *passStr = nil;
    NSString *bundleId = [NSString stringWithUTF8String:APPLICATION_IDENTIFIER];
    NSDictionary *query = @{
                            (__bridge id)kSecClass : (__bridge id)kSecClassGenericPassword,
                            (__bridge id)kSecAttrService : bundleId,
                            (__bridge id)kSecAttrAccount : accountKeyStr,
                            (__bridge id)kSecMatchLimit : (__bridge id)kSecMatchLimitOne,
                            (__bridge id)kSecReturnData : (__bridge id)kCFBooleanTrue,
                            (__bridge id)kSecAttrAccessGroup: bundleId,
                            };
    OSStatus results = SecItemCopyMatching((__bridge CFDictionaryRef)query, (CFTypeRef *)&copyResult);
    if (results == errSecSuccess) {
        passStr = [[NSString alloc] initWithBytes:[(__bridge_transfer NSData *)copyResult bytes]
                                           length:[(__bridge NSData *)copyResult length] encoding:NSUTF8StringEncoding];
    } else if (results != errSecItemNotFound) {
        NSLog(@"[VPNDaemonListener] error obtaining password data: %ld", (long)results);
        if (@available(tvOS 11.3, *)) {
            NSString *errMessage = CFBridgingRelease(SecCopyErrorMessageString(results, nil));
            NSLog(@"%@", errMessage);
        }
    }
    
    return passStr;
}

+ (OSStatus)removeKeychanItemForAccount:(NSString *)accountKeyStr {
    NSString *bundleId = [NSString stringWithUTF8String:APPLICATION_IDENTIFIER];
    NSDictionary *query = @{
                            (__bridge id)kSecClass : (__bridge id)kSecClassGenericPassword,
                            (__bridge id)kSecAttrService : bundleId,
                            (__bridge id)kSecAttrAccount : accountKeyStr,
                            (__bridge id)kSecReturnPersistentRef : (__bridge id)kCFBooleanTrue,
                            (__bridge id)kSecAttrAccessGroup: bundleId,
                            };
    OSStatus result = SecItemDelete((__bridge CFDictionaryRef)query);
    if (result != errSecSuccess && result != errSecItemNotFound) {
        if (@available(tvOS 11.3, *)) {
            NSString *errMessage = CFBridgingRelease(SecCopyErrorMessageString(result, nil));
            NSLog(@"%@", errMessage);
        }
        NSLog(@"[VPNDaemonListener] error deleting password entry %@ with status: %ld", query, (long)result);
    }
    
    return result;
}

+ (OSStatus)storePassword:(NSString *)passwordStr forAccount:(NSString *)accountKeyStr {
    CFTypeRef result = NULL;
    NSString *bundleId = [NSString stringWithUTF8String:APPLICATION_IDENTIFIER];
    NSData *valueData = [passwordStr dataUsingEncoding:NSUTF8StringEncoding];
    NSDictionary *secItem = @{
        (__bridge id)kSecClass : (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService : bundleId,
        (__bridge id)kSecAttrAccessible : (__bridge id)kSecAttrAccessibleAlways,
        (__bridge id)kSecAttrSynchronizable : (__bridge id)kCFBooleanFalse,
        (__bridge id)kSecAttrAccount : accountKeyStr,
        (__bridge id)kSecValueData : valueData,
        (__bridge id)kSecAttrAccessGroup: bundleId,
    };
    OSStatus status = SecItemAdd((__bridge CFDictionaryRef)secItem, &result);
    if (status == errSecSuccess) {
        //NSLog(@"[VPNDaemonListener] successfully stored password %@ for %@", passwordStr, accountKeyStr);
    } else {
        if (status == errSecDuplicateItem){
            NSLog(@"[VPNDaemonListener] duplicate item exists for %@ removing and re-adding.", accountKeyStr);
            [self removeKeychanItemForAccount:accountKeyStr];
            return [self storePassword:passwordStr forAccount:accountKeyStr];
        }
        NSLog(@"[VPNDaemonListener] error storing password (%@): %ld", passwordStr, (long)status);
    }
    return status;
}


//////////////////////////////////////////////////////////////////////////
// XPC Handling
//////////////////////////////////////////////////////////////////////////

- (BOOL)listener:(NSXPCListener *)listener shouldAcceptNewConnection:(NSXPCConnection *)newConnection {
    // Configure bi-directional communication
    NSLog(@"*** [vpnd] :: shouldAcceptNewConnection recieved.");
    
    [newConnection setExportedInterface:[NSXPCInterface interfaceWithProtocol:@protocol(VPNDaemonProtocol)]];
    [newConnection setExportedObject:self];
    
    self.xpcConnection = newConnection;
    
    // State management for the main application
    // When it is e.g. killed, then the invalidation handler is called
    __weak VPNDaemonListener *weakSelf = self;
    self.xpcConnection.interruptionHandler = ^{
        NSLog(@"*** vpnd :: Interruption handler called");
        [weakSelf.xpcConnection invalidate];
        weakSelf.xpcConnection = nil;
    };
    self.xpcConnection.invalidationHandler = ^{
        NSLog(@"*** vpnd :: Invalidation handler called");
        [weakSelf.xpcConnection invalidate];
        weakSelf.xpcConnection = nil;
    };
    
    newConnection.remoteObjectInterface = [NSXPCInterface interfaceWithProtocol: @protocol(VPNApplicationProtocol)];
    [newConnection resume];

    return YES;
}

//this is currently unused in nitoTV but the mobileconfigs from guardian expire in 30 days so this is the scaffolding to handle that.
- (void)applicationRequestExpirationStatus {
    NSDate *expirationDate = [[NSUserDefaults standardUserDefaults] objectForKey:kMCPayloadExpirationDate];
    if ([expirationDate compare:[NSDate date]] == NSOrderedAscending){
        [[self.xpcConnection remoteObjectProxy] daemonProfileExpired:true];
    } else {
        [[self.xpcConnection remoteObjectProxy] daemonProfileExpired:false];
    }
}

//how nitoTV toggles the VPN on/off
- (void)applicationRequestsToggleVPN {
    [self toggleVPN];
}

//how nitoTV requests the current status
- (void)applicationRequestsVPNStatus {
    NSLog(@"*** vpnd :: applicationRequestsVPNStatus" );
    NEVPNStatus status = [VPNDaemonListener currentVPNStatusWithRefresh:true];
    [[self.xpcConnection remoteObjectProxy] daemonReportsStatus:status];
}

//unused
- (void)applicationDidLaunch {
    
}

//////////////////////////////////////////////////////////////////////////
// Daemon protocol
//////////////////////////////////////////////////////////////////////////

//unused
- (void)applicationDidFinishTask {
    NSLog(@"*** [vpnd] :: applicationDidFinishTask recieved.");
    
    
}

//unused
- (void)applicationRequestsPreferencesUpdate {
    NSLog(@"*** [vpnd] :: applicationRequestsPreferencesUpdate recieved.");
    
    // Update our internal preferences from NSUserDefaults' shared suite.
    [self reloadSettings];
    
}


@end
