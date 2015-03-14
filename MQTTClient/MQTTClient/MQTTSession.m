//
// MQTTSession.m
// MQTTClient.framework
//
// Copyright (c) 2013-2015, Christoph Krey
//
// based on
//
// Copyright (c) 2011, 2013, 2lemetry LLC
// 
// All rights reserved. This program and the accompanying materials
// are made available under the terms of the Eclipse Public License v1.0
// which accompanies this distribution, and is available at
// http://www.eclipse.org/legal/epl-v10.html
// 
// Contributors:
//    Kyle Roche - initial API and implementation and/or initial documentation
// 

/**
 Using MQTT in your Objective-C application
 
 @author Christoph Krey krey.christoph@gmail.com
 @see http://mqtt.org
 */

#import "MQTTSession.h"
#import "MQTTTxFlow.h"
#import "MQTTDecoder.h"
#import "MQTTEncoder.h"
#import "MQTTMessage.h"
#import "SRWebSocket.h"

#import <CFNetwork/CFSocketStream.h>

@interface MQTTSession() <MQTTDecoderDelegate, MQTTEncoderDelegate, SRWebSocketDelegate>
@property (nonatomic, readwrite) MQTTSessionStatus status;

@property (strong, nonatomic) NSTimer *keepAliveTimer;
@property (strong, nonatomic) NSTimer *checkDupTimer;

@property (strong, nonatomic) MQTTEncoder *encoder;
@property (strong, nonatomic) MQTTDecoder *decoder;
@property (strong, nonatomic) MQTTSession *selfReference;
@property (nonatomic) UInt16 txMsgId;
@property (strong, nonatomic) NSMutableDictionary *txFlows;
@property (strong, nonatomic) NSMutableDictionary *rxFlows;
@property (strong, nonatomic) NSMutableArray *queue;

@property (nonatomic) BOOL synchronPub;
@property (nonatomic) UInt16 synchronPubMid;
@property (nonatomic) BOOL synchronUnsub;
@property (nonatomic) UInt16 synchronUnsubMid;
@property (nonatomic) BOOL synchronSub;
@property (nonatomic) UInt16 synchronSubMid;
@property (nonatomic) BOOL synchronConnect;
@property (nonatomic) BOOL synchronDisconnect;

@property (strong, nonatomic) SRWebSocket *websocket;
@property (nonatomic) BOOL synchronWSConnect;

@end

#define DUPTIMEOUT 20
#define DUPLOOP 5

#ifdef DEBUG
#define DEBUGSESS FALSE
#else
#define DEBUGSESS FALSE
#endif

@implementation MQTTSession

- (MQTTSession *)init
{
    return [self initWithClientId:[NSString stringWithFormat:@"MQTTClient-%f",
                                   fmod([[NSDate date] timeIntervalSince1970], 10.0)]
                         userName:nil
                         password:nil
                        keepAlive:60
                     cleanSession:YES
                             will:NO
                        willTopic:nil
                          willMsg:nil
                          willQoS:0
                   willRetainFlag:NO
                    protocolLevel:4
                          runLoop:nil
                          forMode:nil];
}

- (MQTTSession *)initWithClientId:(NSString *)clientId
              userName:(NSString *)userName
              password:(NSString *)password
             keepAlive:(UInt16)keepAliveInterval
          cleanSession:(BOOL)cleanSessionFlag
                  will:(BOOL)willFlag
             willTopic:(NSString *)willTopic
               willMsg:(NSData *)willMsg
               willQoS:(MQTTQosLevel)willQoS
        willRetainFlag:(BOOL)willRetainFlag
         protocolLevel:(UInt8)protocolLevel
               runLoop:(NSRunLoop *)runLoop
               forMode:(NSString *)runLoopMode
{
    self = [super init];
    if (DEBUGSESS) NSLog(@"MQTTClient %s %s", __DATE__, __TIME__);

    if (DEBUGSESS) NSLog(@"%@ initWithClientId:%@ userName:%@ password:%@ keepAlive:%d cleanSession:%d will:%d willTopic:%@ willTopic:%@ willQos:%d willRetainFlag:%d protocolLevel:%d runLoop:%@ forMode:%@",
          self,
          clientId,
          userName,
          password,
          keepAliveInterval,
          cleanSessionFlag,
          willFlag,
          willTopic,
          willMsg,
          willQoS,
          willRetainFlag,
          protocolLevel,
          @"runLoop",
          runLoopMode);
    
    self.clientId = clientId;
    self.userName = userName;
    self.password = password;
    self.keepAliveInterval = keepAliveInterval;
    self.cleanSessionFlag = cleanSessionFlag;
    self.willFlag = willFlag;
    self.willTopic = willTopic;
    self.willMsg = willMsg;
    self.willQoS = willQoS;
    self.willRetainFlag = willRetainFlag;
    self.protocolLevel = protocolLevel;
    self.runLoop = runLoop;
    self.runLoopMode = runLoopMode;
   
    self.queue = [NSMutableArray array];
    self.txMsgId = 1;
    self.txFlows = [[NSMutableDictionary alloc] init];
    self.rxFlows = [[NSMutableDictionary alloc] init];
    
    if ([self.delegate respondsToSelector:@selector(buffered:queued:flowingIn:flowingOut:)]) {
        [self.delegate buffered:self
                         queued:[self.queue count]
                      flowingIn:[self.rxFlows count]
                     flowingOut:[self.txFlows count]];
    }
    
    return self;
}

- (void)setClientId:(NSString *)clientId
{
    if (!clientId) {
        clientId = [NSString stringWithFormat:@"MQTTClient%.0f",fmod([[NSDate date] timeIntervalSince1970], 1.0) * 1000000.0];
    }
    
    //NSAssert(clientId.length > 0 || self.cleanSessionFlag, @"clientId must be at least 1 character long if cleanSessionFlag is off");
    
    //NSAssert([clientId dataUsingEncoding:NSUTF8StringEncoding], @"clientId contains non-UTF8 characters");
    //NSAssert([clientId dataUsingEncoding:NSUTF8StringEncoding].length <= 65535L, @"clientId may not be longer than 65535 bytes in UTF8 representation");
    
    _clientId = clientId;
}

- (void)setUserName:(NSString *)userName
{
    if (userName) {
        //NSAssert([userName dataUsingEncoding:NSUTF8StringEncoding], @"userName contains non-UTF8 characters");
        //NSAssert([userName dataUsingEncoding:NSUTF8StringEncoding].length <= 65535L, @"userName may not be longer than 65535 bytes in UTF8 representation");
    }
    
    _userName = userName;
}

- (void)setPassword:(NSString *)password
{
    if (password) {
        //NSAssert(self.userName, @"password specified without userName");
        //NSAssert([password dataUsingEncoding:NSUTF8StringEncoding], @"password contains non-UTF8 characters");
        //NSAssert([password dataUsingEncoding:NSUTF8StringEncoding].length <= 65535L, @"password may not be longer than 65535 bytes in UTF8 representation");
    }
    _password = password;
}

- (void)setProtocolLevel:(UInt8)protocolLevel
{
    //NSAssert(protocolLevel == 3 || protocolLevel == 4, @"allowed protocolLevel values are 3 or 4 only");

    _protocolLevel = protocolLevel;
}

- (void)setRunLoop:(NSRunLoop *)runLoop
{
    if (!runLoop ) {
        runLoop = [NSRunLoop currentRunLoop];
    }
    _runLoop = runLoop;
}

- (void)setRunLoopMode:(NSString *)runLoopMode
{
    if (!runLoopMode) {
        runLoopMode = NSRunLoopCommonModes;
    }
    _runLoopMode = runLoopMode;
}

- (id)initWithClientId:(NSString*)theClientId {
    return [self initWithClientId:theClientId
                         userName:nil
                         password:nil
                        keepAlive:60
                     cleanSession:YES
                             will:NO
                        willTopic:nil
                          willMsg:nil
                          willQoS:MQTTQosLevelAtLeastOnce
                   willRetainFlag:FALSE
                    protocolLevel:4
                          runLoop:nil
                          forMode:nil];
}

- (id)initWithClientId:(NSString*)theClientId
               runLoop:(NSRunLoop*)theRunLoop
               forMode:(NSString*)theRunLoopMode {
    return [self initWithClientId:theClientId
                         userName:nil
                         password:nil
                        keepAlive:60
                     cleanSession:YES
                             will:NO
                        willTopic:nil
                          willMsg:nil
                          willQoS:MQTTQosLevelAtLeastOnce
                   willRetainFlag:FALSE
                    protocolLevel:4
                          runLoop:theRunLoop
                          forMode:theRunLoopMode];
}

- (id)initWithClientId:(NSString*)theClientId
              userName:(NSString*)theUsername
              password:(NSString*)thePassword {
    return [self initWithClientId:theClientId
                         userName:theUsername
                         password:thePassword
                        keepAlive:60
                     cleanSession:YES
                             will:NO
                        willTopic:nil
                          willMsg:nil
                          willQoS:MQTTQosLevelAtLeastOnce
                   willRetainFlag:FALSE
                    protocolLevel:4
                          runLoop:nil
                          forMode:nil];
}

- (id)initWithClientId:(NSString*)theClientId
              userName:(NSString*)theUserName
              password:(NSString*)thePassword
               runLoop:(NSRunLoop*)theRunLoop
               forMode:(NSString*)theRunLoopMode {
    return [self initWithClientId:theClientId
                         userName:theUserName
                         password:thePassword
                        keepAlive:60
                     cleanSession:YES
                             will:NO
                        willTopic:nil
                          willMsg:nil
                          willQoS:MQTTQosLevelAtLeastOnce
                   willRetainFlag:FALSE
                    protocolLevel:4
                          runLoop:theRunLoop
                          forMode:theRunLoopMode];
}

- (id)initWithClientId:(NSString*)theClientId
              userName:(NSString*)theUsername
              password:(NSString*)thePassword
             keepAlive:(UInt16)theKeepAliveInterval
          cleanSession:(BOOL)cleanSessionFlag {
    return [self initWithClientId:theClientId
                         userName:theUsername
                         password:thePassword
                        keepAlive:theKeepAliveInterval
                     cleanSession:cleanSessionFlag
                             will:NO
                        willTopic:nil
                          willMsg:nil
                          willQoS:MQTTQosLevelAtLeastOnce
                   willRetainFlag:FALSE
                    protocolLevel:4
                          runLoop:nil
                          forMode:nil];
}

- (id)initWithClientId:(NSString*)theClientId
              userName:(NSString*)theUsername
              password:(NSString*)thePassword
             keepAlive:(UInt16)theKeepAlive
          cleanSession:(BOOL)theCleanSessionFlag
               runLoop:(NSRunLoop*)theRunLoop
               forMode:(NSString*)theMode {
    return [self initWithClientId:theClientId
                         userName:theUsername
                         password:thePassword
                        keepAlive:theKeepAlive
                     cleanSession:theCleanSessionFlag
                             will:NO
                        willTopic:nil
                          willMsg:nil
                          willQoS:MQTTQosLevelAtLeastOnce
                   willRetainFlag:FALSE
                    protocolLevel:4
                          runLoop:theRunLoop
                          forMode:theMode];
}

- (id)initWithClientId:(NSString*)theClientId
              userName:(NSString*)theUserName
              password:(NSString*)thePassword
             keepAlive:(UInt16)theKeepAliveInterval
          cleanSession:(BOOL)theCleanSessionFlag
             willTopic:(NSString*)willTopic
               willMsg:(NSData*)willMsg
               willQoS:(UInt8)willQoS
        willRetainFlag:(BOOL)willRetainFlag {
    return [self initWithClientId:theClientId
                         userName:theUserName
                         password:thePassword
                        keepAlive:theKeepAliveInterval
                     cleanSession:theCleanSessionFlag
                             will:YES
                        willTopic:willTopic
                          willMsg:willMsg
                          willQoS:willQoS
                   willRetainFlag:willRetainFlag
                    protocolLevel:4
                          runLoop:nil
                          forMode:nil];
}

- (id)initWithClientId:(NSString*)theClientId
              userName:(NSString*)theUserName
              password:(NSString*)thePassword
             keepAlive:(UInt16)theKeepAliveInterval
          cleanSession:(BOOL)theCleanSessionFlag
             willTopic:(NSString*)willTopic
               willMsg:(NSData*)willMsg
               willQoS:(UInt8)willQoS
        willRetainFlag:(BOOL)willRetainFlag
               runLoop:(NSRunLoop*)theRunLoop
               forMode:(NSString*)theRunLoopMode {
    return [self initWithClientId:theClientId
                         userName:theUserName
                         password:thePassword
                        keepAlive:theKeepAliveInterval
                     cleanSession:theCleanSessionFlag
                             will:YES
                        willTopic:willTopic
                          willMsg:willMsg
                          willQoS:willQoS
                   willRetainFlag:willRetainFlag
                    protocolLevel:4
                          runLoop:theRunLoop
                          forMode:theRunLoopMode];
}

- (id)initWithClientId:(NSString*)theClientId
             keepAlive:(UInt16)theKeepAliveInterval
        connectMessage:(MQTTMessage*)theConnectMessage
               runLoop:(NSRunLoop*)theRunLoop
               forMode:(NSString*)theRunLoopMode {
    self.connectMessage = theConnectMessage;
    return [self initWithClientId:theClientId
                         userName:nil
                         password:nil
                        keepAlive:theKeepAliveInterval
                     cleanSession:YES
                             will:NO
                        willTopic:nil
                          willMsg:nil
                          willQoS:MQTTQosLevelAtLeastOnce
                   willRetainFlag:FALSE
                    protocolLevel:4
                          runLoop:theRunLoop
                          forMode:theRunLoopMode];
}

- (void)connectToHost:(NSString*)host port:(UInt32)port usingSSL:(BOOL)usingSSL
{
    if (DEBUGSESS) NSLog(@"%@ connectToHost:%@ port:%d usingSSL:%d]", self, host, (unsigned int)port, usingSSL);
    
    self.selfReference = self;
    self.synchronWSConnect = TRUE;
    
    if (!host) {
        host = @"localhost";
    }
    
    self.status = MQTTSessionStatusCreated;
    
    self.websocket.delegate = nil;
    [self.websocket close];
    
    NSString *protocol = (usingSSL) ? @"wss" : @"ws";
    NSString *portString = (port == 0) ? @"" : [NSString stringWithFormat:@":%d",(unsigned int)port];
    NSString *path = @"/mqtt";
    self.websocket = [[SRWebSocket alloc] initWithURLRequest:[NSURLRequest requestWithURL:[NSURL URLWithString:[NSString stringWithFormat:@"%@://%@%@%@",protocol,host,portString,path]]]];
    
    self.websocket.delegate = self;
    
    [self.websocket open];
    
    //wait for 3 seconds
    int connectEmergencyBrake = 0;
    while (self.synchronWSConnect && connectEmergencyBrake < 30) {
        if (DEBUGSESS) NSLog(@"%@ waiting for connect", self);
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.1]];
        connectEmergencyBrake++;
    }
    
    self.encoder = [[MQTTEncoder alloc] initWithWebSocket:self.websocket
                                                  runLoop:self.runLoop
                                              runLoopMode:self.runLoopMode];
    
    self.decoder = [[MQTTDecoder alloc] initWithWebSocket:self.websocket
                                                  runLoop:self.runLoop
                                              runLoopMode:self.runLoopMode];
    
    self.encoder.delegate = self;
    self.decoder.delegate = self;
    
    [self.encoder open];
    [self.decoder open];
    
    if(connectEmergencyBrake >= 30 && self.synchronWSConnect){
        NSDictionary *errorDictionary = @{ NSLocalizedDescriptionKey : @"Connection creation timeout" };
        
        NSError *anError = [[NSError alloc] initWithDomain:@"WSConnection"
                                                      code:1000 userInfo:errorDictionary];
        [self webSocket:self.websocket didFailWithError:anError];
    }
}

- (void)connectToHost:(NSString*)ip port:(UInt32)port {
    [self connectToHost:ip port:port usingSSL:NO];
}

- (void)connectToHost:(NSString*)ip port:(UInt32)port withConnectionHandler:(void (^)(MQTTSessionEvent event))connHandler messageHandler:(void (^)(NSData* data, NSString* topic))messHandler {
    self.messageHandler = messHandler;
    self.connectionHandler = connHandler;

    [self connectToHost:ip port:port usingSSL:NO];
}

- (void)connectToHost:(NSString*)ip port:(UInt32)port usingSSL:(BOOL)usingSSL withConnectionHandler:(void (^)(MQTTSessionEvent event))connHandler messageHandler:(void (^)(NSData* data, NSString* topic))messHandler {
    self.messageHandler = messHandler;
    self.connectionHandler = connHandler;

    [self connectToHost:ip port:port usingSSL:usingSSL];
}


- (BOOL)connectAndWaitToHost:(NSString*)host port:(UInt32)port usingSSL:(BOOL)usingSSL
{
    self.synchronConnect = TRUE;
    
    [self connectToHost:host port:port usingSSL:usingSSL];
    
    while (self.synchronConnect) {
        if (DEBUGSESS) NSLog(@"%@ waiting for connect", self);
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.1]];
    }
    
    if (DEBUGSESS) NSLog(@"%@ end connect", self);

    return (self.status == MQTTSessionStatusConnected);
}

- (UInt16)subscribeToTopic:(NSString *)topic
                   atLevel:(MQTTQosLevel)qosLevel
{
    if (DEBUGSESS) NSLog(@"%@ subscribeToTopic:%@ atLevel:%d]", self, topic, qosLevel);
    
    //NSAssert(qosLevel >= 0 && qosLevel <= 2, @"qosLevel must be 0, 1, or 2");

    UInt16 mid = [self nextMsgId];
    [self send:[MQTTMessage subscribeMessageWithMessageId:mid
                                                   topics:topic ? @{topic: @(qosLevel)} : @{}]];
    return mid;
}

- (void)subscribeTopic:(NSString*)theTopic {
    [self subscribeToTopic:theTopic atLevel:MQTTQosLevelAtLeastOnce];
}

- (BOOL)subscribeAndWaitToTopic:(NSString *)topic atLevel:(MQTTQosLevel)qosLevel
{
    self.synchronSub = TRUE;
    UInt16 mid = [self subscribeToTopic:topic atLevel:qosLevel];
    self.synchronSubMid = mid;
    
    while (self.synchronSub) {
        if (DEBUGSESS) NSLog(@"%@ waiting for suback %d", self, mid);
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.1]];
    }
    
    if (DEBUGSESS) NSLog(@"%@ end subscribe", self);

    if (self.synchronSubMid == mid) {
        return TRUE;
    } else {
        return FALSE;
    }
}

- (UInt16)subscribeToTopics:(NSDictionary *)topics
{
   if (DEBUGSESS) NSLog(@"%@ subscribeToTopics:%@]", self, topics);

    //for (NSNumber *qos in [topics allValues]) {
        //NSAssert([qos intValue] >= 0 && [qos intValue] <= 2, @"qosLevel must be 0, 1, or 2");
    //}

    UInt16 mid = [self nextMsgId];
    [self send:[MQTTMessage subscribeMessageWithMessageId:mid
                                                   topics:topics]];
    return mid;
}

- (BOOL)subscribeAndWaitToTopics:(NSDictionary *)topics
{
    self.synchronSub = TRUE;
    UInt16 mid = [self subscribeToTopics:topics];
    self.synchronSubMid = mid;
    
    while (self.synchronSub) {
        if (DEBUGSESS) NSLog(@"%@ waiting for suback %d", self, mid);
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.1]];
    }
    
    if (DEBUGSESS) NSLog(@"%@ end subscribe", self);

    if (self.synchronSubMid == mid) {
        return TRUE;
    } else {
        return FALSE;
    }
}

- (UInt16)unsubscribeTopic:(NSString*)theTopic
{
    if (DEBUGSESS) NSLog(@"%@ unsubscribeTopic:%@", self, theTopic);
    UInt16 mid = [self nextMsgId];
    [self send:[MQTTMessage unsubscribeMessageWithMessageId:mid
                                                     topics:theTopic ? @[theTopic] : @[]]];
    return mid;
}

- (BOOL)unsubscribeAndWaitTopic:(NSString *)theTopic
{
    self.synchronUnsub = TRUE;
    UInt16 mid = [self unsubscribeTopic:theTopic];
    self.synchronUnsubMid = mid;
    
    while (self.synchronUnsub) {
        if (DEBUGSESS) NSLog(@"%@ waiting for unsuback %d", self, mid);
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.1]];
    }
    
    if (DEBUGSESS) NSLog(@"%@ end unsubscribe", self);

    if (self.synchronUnsubMid == mid) {
        return TRUE;
    } else {
        return FALSE;
    }
}

- (UInt16)unsubscribeTopics:(NSArray *)theTopics
{
    if (DEBUGSESS) NSLog(@"%@ unsubscribeTopics:%@", self, theTopics);
    UInt16 mid = [self nextMsgId];
    [self send:[MQTTMessage unsubscribeMessageWithMessageId:mid
                                                      topics:theTopics]];
    return mid;
}

- (BOOL)unsubscribeAndWaitTopics:(NSArray *)theTopics
{
    self.synchronUnsub = TRUE;
    UInt16 mid = [self unsubscribeTopics:theTopics];
    self.synchronUnsubMid = mid;
    
    while (self.synchronUnsub) {
        if (DEBUGSESS) NSLog(@"%@ waiting for unsuback %d", self, mid);
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.1]];
    }
    
    if (DEBUGSESS) NSLog(@"%@ end unsubscribe", self);

    if (self.synchronUnsubMid == mid) {
        return TRUE;
    } else {
        return FALSE;
    }
}

- (UInt16)publishData:(NSData*)data
              onTopic:(NSString*)topic
               retain:(BOOL)retainFlag
                  qos:(MQTTQosLevel)qos
{
    if (DEBUGSESS) NSLog(@"%@ publishData:%@... onTopic:%@ retain:%d qos:%ld",
          self,
          [data subdataWithRange:NSMakeRange(0, MIN(16, data.length))],
          topic,
          retainFlag,
          (long)qos);
    
    if (!data) {
        data = [[NSData alloc] init];
    }
    
    //NSAssert(qos >= 0 && qos <= 2, @"qos must be 0, 1, or 2");
    
    UInt16 msgId = [self nextMsgId];
    MQTTMessage *msg = [MQTTMessage publishMessageWithData:data
                                                   onTopic:topic
                                                       qos:qos
                                                     msgId:qos ? msgId : 0
                                                retainFlag:retainFlag
                                                   dupFlag:FALSE];
    if (qos) {
        MQttTxFlow *flow = [[MQttTxFlow alloc] init];
        flow.msg = msg;
        flow.deadline = [NSDate dateWithTimeIntervalSinceNow:DUPTIMEOUT];
        self.txFlows[[NSNumber numberWithUnsignedInt:(uint)msgId]] = flow;
        if ([self.delegate respondsToSelector:@selector(buffered:queued:flowingIn:flowingOut:)]) {
            [self.delegate buffered:self
                             queued:[self.queue count]
                          flowingIn:[self.rxFlows count]
                         flowingOut:[self.txFlows count]];
        }
    }
    [self send:msg];
    
    return qos ? msgId : 0;
}

- (BOOL)publishAndWaitData:(NSData*)data
                     onTopic:(NSString*)topic
                      retain:(BOOL)retainFlag
                         qos:(MQTTQosLevel)qos
{
    if (qos != MQTTQoSLevelAtMostOnce) {
        self.synchronPub = TRUE;
    }

    UInt16 mid = [self publishData:data onTopic:topic retain:retainFlag qos:qos];
    if (qos == MQTTQoSLevelAtMostOnce) {
        return TRUE;
    } else {
        self.synchronPubMid = mid;
        
        while (self.synchronPub) {
            if (DEBUGSESS) NSLog(@"%@ waiting for mid %d", self, mid);
            [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.1]];
        }
        
        if (DEBUGSESS) NSLog(@"%@ end publish", self);

        if (self.synchronPubMid == mid) {
            return TRUE;
        } else {
            return FALSE;
        }
    }
}

- (void)publishData:(NSData*)theData onTopic:(NSString*)theTopic {
    [self publishData:theData onTopic:theTopic retain:NO qos:MQTTQosLevelAtLeastOnce];
}

- (void)publishDataAtLeastOnce:(NSData*)theData onTopic:(NSString*)theTopic {
    [self publishData:theData onTopic:theTopic retain:NO qos:MQTTQosLevelAtLeastOnce];
}

- (void)publishDataAtLeastOnce:(NSData*)theData onTopic:(NSString*)theTopic retain:(BOOL)retainFlag {
    [self publishData:theData onTopic:theTopic retain:retainFlag qos:MQTTQosLevelAtLeastOnce];
}

- (void)publishDataAtMostOnce:(NSData*)theData onTopic:(NSString*)theTopic {
    [self publishData:theData onTopic:theTopic retain:NO qos:MQTTQoSLevelAtMostOnce];
}

- (void)publishDataAtMostOnce:(NSData*)theData onTopic:(NSString*)theTopic retain:(BOOL)retainFlag {
    [self publishData:theData onTopic:theTopic retain:retainFlag qos:MQTTQoSLevelAtMostOnce];
}

- (void)publishDataExactlyOnce:(NSData*)theData onTopic:(NSString*)theTopic {
    [self publishData:theData onTopic:theTopic retain:NO qos:MQTTQosLevelExactlyOnce];
}

- (void)publishDataExactlyOnce:(NSData*)theData onTopic:(NSString*)theTopic retain:(BOOL)retainFlag {
    [self publishData:theData onTopic:theTopic retain:retainFlag qos:MQTTQosLevelExactlyOnce];
}

- (void)publishJson:(id)payload onTopic:(NSString*)theTopic {
    NSData *data = [NSJSONSerialization dataWithJSONObject:payload options:0 error:nil];
    if (data) {
        [self publishData:payload onTopic:theTopic retain:FALSE qos:MQTTQosLevelAtLeastOnce];
    }
}

- (void)close
{
    if (DEBUGSESS) NSLog(@"%@ close", self);
    
    if (self.status == MQTTSessionStatusConnected) {
        if (DEBUGSESS) NSLog(@"%@ disconnecting", self);
        self.status = MQTTSessionStatusDisconnecting;
        [self send:[MQTTMessage disconnectMessage]];
    } else {
        [self closeInternal];
    }
}

- (void)closeAndWait
{
    self.synchronDisconnect = TRUE;
    [self close];
    
    while (self.synchronDisconnect) {
        if (DEBUGSESS) NSLog(@"%@ waiting for close", self);
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.1]];
    }
    if (DEBUGSESS) NSLog(@"%@ end close", self);

}

- (void)closeInternal
{
    if (DEBUGSESS) NSLog(@"%@ closeInternal", self);
    
    if (self.checkDupTimer) {
        [self.checkDupTimer invalidate];
        self.checkDupTimer = nil;
    }
    
    if (self.keepAliveTimer) {
        [self.keepAliveTimer invalidate];
        self.keepAliveTimer = nil;
    }
    
    [self.encoder close];
    [self.decoder close];
    self.encoder.delegate = nil;
    self.decoder.delegate = nil;

    self.status = MQTTSessionStatusClosed;
    if ([self.delegate respondsToSelector:@selector(handleEvent:event:error:)]) {
        [self.delegate handleEvent:self event:MQTTSessionEventConnectionClosed error:nil];
    }
    if ([self.delegate respondsToSelector:@selector(connectionClosed:)]) {
        [self.delegate connectionClosed:self];
    }

    if ([self.delegate respondsToSelector:@selector(buffered:queued:flowingIn:flowingOut:)]) {
        [self.delegate buffered:self
                         queued:[self.queue count]
                      flowingIn:[self.rxFlows count]
                     flowingOut:[self.txFlows count]];
    }
    self.synchronPub = FALSE;
    self.synchronPubMid = 0;
    self.synchronSub = FALSE;
    self.synchronSubMid = 0;
    self.synchronUnsub = FALSE;
    self.synchronUnsubMid = 0;
    self.synchronConnect = FALSE;
    self.synchronDisconnect = FALSE;
    self.selfReference = nil;
}


- (void)keepAlive:(NSTimer *)timer
{
    if (DEBUGSESS)  NSLog(@"%@ keepAlive %@ @%.0f", self, self.clientId, [[NSDate date] timeIntervalSince1970]);
    if ([self.encoder status] == MQTTEncoderStatusReady) {
        MQTTMessage *msg = [MQTTMessage pingreqMessage];
        [self.encoder encodeMessage:msg];
    }
}

- (void)checkDup:(NSTimer *)timer
{
    if (DEBUGSESS)  NSLog(@"%@ checkDup %@ @%.0f", self, self.clientId, [[NSDate date] timeIntervalSince1970]);
    [self checkTxFlows];
}

- (void)checkTxFlows
{
    for (NSNumber *msgId in [self.txFlows allKeys]) {
        MQttTxFlow *flow = (self.txFlows)[msgId];
        if ([flow.deadline compare:[NSDate date]] == NSOrderedAscending) {
            if (DEBUGSESS)  NSLog(@"%@ send dup %@ %@", self, self.clientId, msgId);
            MQTTMessage *msg = [flow msg];
            flow.deadline = [NSDate dateWithTimeIntervalSinceNow:DUPTIMEOUT];
            if (msg.type == MQTTPublish) {
                msg.dupFlag = TRUE;
            }
            [self send:msg];
        }
    }
}

- (void)encoder:(MQTTEncoder*)sender handleEvent:(MQTTEncoderEvent)eventCode error:(NSError *)error
{
    if (DEBUGSESS) {
        NSArray *events = @[
                            @"MQTTEncoderEventReady",
                            @"MQTTEncoderEventErrorOccurred"
                            ];
        
        NSLog(@"%@ encoder handleEvent: %@ (%d) %@", self, events[eventCode % [events count]], eventCode, [error description]);
    }
    switch (eventCode) {
        case MQTTEncoderEventReady:
            switch (self.status) {
                case MQTTSessionStatusCreated:
                    if (!self.connectMessage) {
                    [sender encodeMessage:[MQTTMessage connectMessageWithClientId:self.clientId
                                                                         userName:self.userName
                                                                         password:self.password
                                                                        keepAlive:self.keepAliveInterval
                                                                     cleanSession:self.cleanSessionFlag
                                                                             will:self.willFlag
                                                                        willTopic:self.willTopic
                                                                          willMsg:self.willMsg
                                                                          willQoS:self.willQoS
                                                                       willRetain:self.willRetainFlag
                                                                    protocolLevel:self.protocolLevel]];
                    } else {
                        [sender encodeMessage:self.connectMessage];
                    }
                    self.status = MQTTSessionStatusConnecting;
                    break;
                case MQTTSessionStatusConnecting:
                    break;
                case MQTTSessionStatusConnected:
                    if ([self.queue count] > 0) {
                        MQTTMessage *msg = (self.queue)[0];
                        [self.queue removeObjectAtIndex:0];
                        if ([self.delegate respondsToSelector:@selector(buffered:queued:flowingIn:flowingOut:)]) {
                            [self.delegate buffered:self
                                             queued:[self.queue count]
                                          flowingIn:[self.rxFlows count]
                                         flowingOut:[self.txFlows count]];
                        }
                        [self.encoder encodeMessage:msg];
                    }
                    [self checkTxFlows];
                    break;
                case MQTTSessionStatusDisconnecting:
                    if (DEBUGSESS) NSLog(@"%@ disconnect sent", self);
                    // [self closeInternal]; rather wait until server closes connect, see issue #10
                    break;
                case MQTTSessionStatusClosed:
                    break;
                case MQTTSessionStatusError:
                    break;
            }
            break;
        case MQTTEncoderEventErrorOccurred:
            [self connectionError:error];
            break;
    }
}

- (void)encoder:(MQTTEncoder *)sender sending:(int)type qos:(int)qos retained:(BOOL)retained duped:(BOOL)duped mid:(UInt16)mid data:(NSData *)data
{
    if ([self.delegate respondsToSelector:@selector(sending:type:qos:retained:duped:mid:data:)]) {
        [self.delegate sending:self type:type qos:qos retained:retained duped:duped mid:mid data:data];
    }
}

- (void)decoder:(MQTTDecoder*)sender handleEvent:(MQTTDecoderEvent)eventCode error:(NSError *)error
{
    if (DEBUGSESS) {
        NSArray *events = @[
                            @"MQTTDecoderEventProtocolError",
                            @"MQTTDecoderEventConnectionClosed",
                            @"MQTTDecoderEventConnectionError"
                            ];
        
        NSLog(@"%@ decoder handleEvent: %@ (%d) %@", self, events[eventCode % [events count]], eventCode, [error description]);
    }
    switch (eventCode) {
        case MQTTDecoderEventConnectionClosed:
            [self error:MQTTSessionEventConnectionClosedByBroker error:error];
            break;
        case MQTTDecoderEventConnectionError:
            [self connectionError:error];
            break;
        case MQTTDecoderEventProtocolError:
            [self protocolError:error];
            break;
    }
}

- (void)decoder:(MQTTDecoder*)sender newMessage:(MQTTMessage*)msg
{
    if ([self.delegate respondsToSelector:@selector(received:type:qos:retained:duped:mid:data:)]) {
        [self.delegate received:self
                           type:msg.type
                            qos:msg.qos
                       retained:msg.retainFlag
                          duped:msg.dupFlag
                            mid:0
                           data:msg.data];
    }
    if ([self.delegate respondsToSelector:@selector(ignoreReceived:type:qos:retained:duped:mid:data:)]) {
        if ([self.delegate ignoreReceived:self
                                     type:msg.type
                                      qos:msg.qos
                                 retained:msg.retainFlag
                                    duped:msg.dupFlag
                                      mid:0
                                     data:msg.data]) {
            return;
        }
    }
    switch (self.status) {
        case MQTTSessionStatusConnecting:
            switch ([msg type]) {
                case MQTTConnack:
                    if ([[msg data] length] != 2) {
                        [self protocolError:[NSError errorWithDomain:@"MQTT"
                                                                code:-2
                                                            userInfo:@{NSLocalizedDescriptionKey : @"MQTT protocol CONNACK expected"}]];
                    }
                    else {
                        const UInt8 *bytes = [[msg data] bytes];
                        if (bytes[1] == 0) {
                            self.status = MQTTSessionStatusConnected;
                            
                            self.checkDupTimer = [NSTimer timerWithTimeInterval:DUPLOOP
                                                                         target:self
                                                                       selector:@selector(checkDup:)
                                                                       userInfo:nil
                                                                        repeats:YES];
                            [self.runLoop addTimer:self.checkDupTimer forMode:self.runLoopMode];
                            
                            self.keepAliveTimer = [NSTimer timerWithTimeInterval:self.keepAliveInterval
                                                                          target:self
                                                                        selector:@selector(keepAlive:)
                                                                        userInfo:nil
                                                                         repeats:YES];
                            [self.runLoop addTimer:self.keepAliveTimer forMode:self.runLoopMode];
                            
                            if ([self.delegate respondsToSelector:@selector(handleEvent:event:error:)]) {
                                [self.delegate handleEvent:self event:MQTTSessionEventConnected error:nil];
                            }
                            if ([self.delegate respondsToSelector:@selector(connected:)]) {
                                [self.delegate connected:self];
                            }
                            if ([self.delegate respondsToSelector:@selector(connected:sessionPresent:)]) {
                                [self.delegate connected:self sessionPresent:((bytes[0] & 0x01) == 0x01)];
                            }

                            if(self.connectionHandler){
                                self.connectionHandler(MQTTSessionEventConnected);
                            }

                            self.synchronConnect = FALSE;
                            
                            if ([self.queue count] > 0) {
                                if (self.encoder.status == MQTTEncoderStatusReady) {
                                    MQTTMessage *msg = (self.queue)[0];
                                    [self.queue removeObjectAtIndex:0];
                                    if ([self.delegate respondsToSelector:@selector(buffered:queued:flowingIn:flowingOut:)]) {
                                        [self.delegate buffered:self
                                                         queued:[self.queue count]
                                                      flowingIn:[self.rxFlows count]
                                                     flowingOut:[self.txFlows count]];
                                    }
                                    [self.encoder encodeMessage:msg];
                                }
                            }
                        }
                        else {
                            NSString *errorDescription;
                            switch (bytes[1]) {
                                case 1:
                                    errorDescription = @"MQTT CONNACK: unacceptable protocol version";
                                    break;
                                case 2:
                                    errorDescription = @"MQTT CONNACK: identifier rejected";
                                    break;
                                case 3:
                                    errorDescription = @"MQTT CONNACK: server unavailable";
                                    break;
                                case 4:
                                    errorDescription = @"MQTT CONNACK: bad user name or password";
                                    break;
                                case 5:
                                    errorDescription = @"MQTT CONNACK: not authorized";
                                    break;
                                default:
                                    errorDescription = @"MQTT CONNACK: reserved for future use";
                                    break;
                            }
                            
                            NSError *error = [NSError errorWithDomain:@"MQTT"
                                                                 code:bytes[1]
                                                             userInfo:@{NSLocalizedDescriptionKey : errorDescription}];
                            [self error:MQTTSessionEventConnectionRefused error:error];
                            if ([self.delegate respondsToSelector:@selector(connectionRefused:error:)]) {
                                [self.delegate connectionRefused:self error:error];
                            }

                        }
                    }
                    break;
                default:
                    [self protocolError:[NSError errorWithDomain:@"MQTT"
                                                            code:-1
                                                        userInfo:@{NSLocalizedDescriptionKey : @"MQTT protocol no CONNACK"}]];
                    break;
            }
            break;
        case MQTTSessionStatusConnected:
            switch ([msg type]) {
                case MQTTPublish:
                    [self handlePublish:msg];
                    break;
                case MQTTPuback:
                    [self handlePuback:msg];
                    break;
                case MQTTPubrec:
                    [self handlePubrec:msg];
                    break;
                case MQTTPubrel:
                    [self handlePubrel:msg];
                    break;
                case MQTTPubcomp:
                    [self handlePubcomp:msg];
                    break;
                case MQTTSuback:
                    [self handleSuback:msg];
                    break;
                case MQTTUnsuback:
                    [self handleUnsuback:msg];
                    break;
                default:
                    break;
            }
            break;
        default:
            break;
    }
}

- (void)handlePublish:(MQTTMessage*)msg
{
    NSData *data = [msg data];
    if ([data length] < 2) {
        return;
    }
    UInt8 const *bytes = [data bytes];
    UInt16 topicLength = 256 * bytes[0] + bytes[1];
    if ([data length] < 2 + topicLength) {
        return;
    }
    NSData *topicData = [data subdataWithRange:NSMakeRange(2, topicLength)];
    NSString *topic = [[NSString alloc] initWithData:topicData
                                            encoding:NSUTF8StringEncoding];
    NSRange range = NSMakeRange(2 + topicLength, [data length] - topicLength - 2);
    data = [data subdataWithRange:range];
    if ([msg qos] == 0) {
        if ([self.delegate respondsToSelector:@selector(newMessage:data:onTopic:qos:retained:mid:)]) {
            [self.delegate newMessage:self data:data onTopic:topic qos:msg.qos retained:msg.retainFlag mid:0];
        }
        if(self.messageHandler){
            self.messageHandler(data, topic);
        }
    } else {
        if ([data length] >= 2) {
            bytes = [data bytes];
            UInt16 msgId = 256 * bytes[0] + bytes[1];
            if (msgId != 0) {
                msg.mid = msgId;
                data = [data subdataWithRange:NSMakeRange(2, [data length] - 2)];
                if ([msg qos] == 1) {
                    if ([self.delegate respondsToSelector:@selector(newMessage:data:onTopic:qos:retained:mid:)]) {
                        [self.delegate newMessage:self data:data onTopic:topic qos:msg.qos retained:msg.retainFlag mid:msgId];
                    }
                    if(self.messageHandler){
                        self.messageHandler(data, topic);
                    }
                    [self send:[MQTTMessage pubackMessageWithMessageId:msgId]];
                    return;
                } else {
                    NSDictionary *dict = @{@"data": data,
                                          @"topic": topic,
                                          @"qos": @(msg.qos),
                                          @"retained": @(msg.retainFlag),
                                          @"mid": @(msgId)};
                    (self.rxFlows)[[NSNumber numberWithUnsignedInt:msgId]] = dict;
                    if ([self.delegate respondsToSelector:@selector(buffered:queued:flowingIn:flowingOut:)]) {
                        [self.delegate buffered:self
                                         queued:[self.queue count]
                                      flowingIn:[self.rxFlows count]
                                     flowingOut:[self.txFlows count]];
                    }
                    [self send:[MQTTMessage pubrecMessageWithMessageId:msgId]];
                }
            }
        }
    }
}

- (void)handlePuback:(MQTTMessage*)msg
{
    if ([[msg data] length] == 2) {
        UInt8 const *bytes = [[msg data] bytes];
        NSNumber *msgId = [NSNumber numberWithUnsignedInt:(256 * bytes[0] + bytes[1])];
        if ([msgId unsignedIntValue] != 0) {
            msg.mid = [msgId unsignedIntValue];
            MQttTxFlow *flow = (self.txFlows)[msgId];
            if (flow != nil) {
                if ([[flow msg] type] == MQTTPublish && [[flow msg] qos] == 1) {
                    
                    [self.txFlows removeObjectForKey:msgId];
                    if ([self.delegate respondsToSelector:@selector(buffered:queued:flowingIn:flowingOut:)]) {
                        [self.delegate buffered:self
                                         queued:[self.queue count]
                                      flowingIn:[self.rxFlows count]
                                     flowingOut:[self.txFlows count]];
                    }
                    if ([self.delegate respondsToSelector:@selector(messageDelivered:msgID:)]) {
                        [self.delegate messageDelivered:self msgID:[msgId unsignedIntValue]];
                    }
                    if (self.synchronPub && self.synchronPubMid == [msgId unsignedIntegerValue]) {
                        self.synchronPub = FALSE;
                    }
                }
            }
        }
    }
}

- (void)handleSuback:(MQTTMessage*)msg
{
    if ([[msg data] length] >= 3) {
        UInt8 const *bytes = [[msg data] bytes];
        NSNumber *msgId = [NSNumber numberWithUnsignedInt:(256 * bytes[0] + bytes[1])];
        msg.mid = [msgId unsignedIntValue];
        NSMutableArray *qoss = [[NSMutableArray alloc] init];
        for (int i = 2; i < [[msg data] length]; i++) {
            [qoss addObject:@(bytes[i])];
        }
        if ([self.delegate respondsToSelector:@selector(subAckReceived:msgID:grantedQoss:)]) {
            [self.delegate subAckReceived:self msgID:msg.mid grantedQoss:qoss];
        }
        if (self.synchronSub && self.synchronSubMid == msg.mid) {
            self.synchronSub = FALSE;
        }
    }
}

- (void)handleUnsuback:(MQTTMessage*)msg
{
    if ([[msg data] length] == 2) {
        UInt8 const *bytes = [[msg data] bytes];
        NSNumber *msgId = [NSNumber numberWithUnsignedInt:(256 * bytes[0] + bytes[1])];
        msg.mid = [msgId unsignedIntValue];
        if ([self.delegate respondsToSelector:@selector(unsubAckReceived:msgID:)]) {
            [self.delegate unsubAckReceived:self msgID:msg.mid];
        }
        if (self.synchronUnsub && self.synchronUnsubMid == msg.mid) {
            self.synchronUnsub = FALSE;
        }
    }
}

- (void)handlePubrec:(MQTTMessage*)msg
{
    if ([[msg data] length] == 2) {
        UInt8 const *bytes = [[msg data] bytes];
        NSNumber *msgId = [NSNumber numberWithUnsignedInt:(256 * bytes[0] + bytes[1])];
        if ([msgId unsignedIntValue] != 0) {
            msg.mid = [msgId unsignedIntValue];
            MQTTMessage *pubrelmsg = [MQTTMessage pubrelMessageWithMessageId:[msgId unsignedIntValue]];
            MQttTxFlow *flow = (self.txFlows)[msgId];
            if (flow != nil) {
                MQTTMessage *flowmsg = [flow msg];
                if ([flowmsg type] == MQTTPublish && [flowmsg qos] == 2) {
                    flow.msg = pubrelmsg;
                    flow.deadline = [NSDate dateWithTimeIntervalSinceNow:DUPTIMEOUT];
                }
            }
            [self send:pubrelmsg];
        }
    }
}

- (void)handlePubrel:(MQTTMessage*)msg
{
    if ([[msg data] length] == 2) {
        UInt8 const *bytes = [[msg data] bytes];
        NSNumber *msgId = [NSNumber numberWithUnsignedInt:(256 * bytes[0] + bytes[1])];
        if ([msgId unsignedIntValue] != 0) {
            msg.mid = [msgId unsignedIntValue];
            NSDictionary *dict = (self.rxFlows)[msgId];
            if (dict != nil) {
                if ([self.delegate respondsToSelector:@selector(newMessage:data:onTopic:qos:retained:mid:)]) {
                    [self.delegate newMessage:self
                                         data:[dict valueForKey:@"data"]
                                      onTopic:[dict valueForKey:@"topic"]
                                          qos:[[dict valueForKey:@"qos"] intValue]
                                     retained:[[dict valueForKey:@"retained"] boolValue]
                                          mid:[[dict valueForKey:@"mid"] unsignedIntValue]
                     ];
                }
                if(self.messageHandler){
                    self.messageHandler([dict valueForKey:@"data"], [dict valueForKey:@"topic"]);
                }

                [self.rxFlows removeObjectForKey:msgId];
                if ([self.delegate respondsToSelector:@selector(buffered:queued:flowingIn:flowingOut:)]) {
                    [self.delegate buffered:self
                                     queued:[self.queue count]
                                  flowingIn:[self.rxFlows count]
                                 flowingOut:[self.txFlows count]];
                }
            }
            [self send:[MQTTMessage pubcompMessageWithMessageId:[msgId unsignedIntegerValue]]];
        }
    }
}

- (void)handlePubcomp:(MQTTMessage*)msg {
    if ([[msg data] length] == 2) {
        UInt8 const *bytes = [[msg data] bytes];
        NSNumber *msgId = [NSNumber numberWithUnsignedInt:(256 * bytes[0] + bytes[1])];
        if ([msgId unsignedIntValue] != 0) {
            msg.mid = [msgId unsignedIntValue];
            MQttTxFlow *flow = (self.txFlows)[msgId];
            if (flow != nil && [[flow msg] type] == MQTTPubrel) {
                [self.txFlows removeObjectForKey:msgId];
                if ([self.delegate respondsToSelector:@selector(buffered:queued:flowingIn:flowingOut:)]) {
                    [self.delegate buffered:self
                                     queued:[self.queue count]
                                  flowingIn:[self.rxFlows count]
                                 flowingOut:[self.txFlows count]];
                }
                if ([self.delegate respondsToSelector:@selector(messageDelivered:msgID:)]) {
                    [self.delegate messageDelivered:self msgID:[msgId unsignedIntValue]];
                }
                if (self.synchronPub && self.synchronPubMid == [msgId unsignedIntegerValue]) {
                    self.synchronPub = FALSE;
                }
            }
        }
    }
}

- (void)connectionError:(NSError *)error {
    [self error:MQTTSessionEventConnectionError error:error];
    if ([self.delegate respondsToSelector:@selector(connectionError:error:)]) {
        [self.delegate connectionError:self error:error];
    }
}

- (void)protocolError:(NSError *)error {
    [self error:MQTTSessionEventProtocolError error:error];
    if ([self.delegate respondsToSelector:@selector(protocolError:error:)]) {
        [self.delegate protocolError:self error:error];
    }
}

- (void)error:(MQTTSessionEvent)eventCode error:(NSError *)error {
    
    self.status = MQTTSessionStatusError;
    [self closeInternal];
    if ([self.delegate respondsToSelector:@selector(handleEvent:event:error:)]) {
        [self.delegate handleEvent:self event:eventCode error:error];
    }

    if(self.connectionHandler){
        self.connectionHandler(eventCode);
    }

    self.synchronPub = FALSE;
    self.synchronPubMid = 0;
    self.synchronSub = FALSE;
    self.synchronSubMid = 0;
    self.synchronUnsub = FALSE;
    self.synchronUnsubMid = 0;
    self.synchronConnect = FALSE;
    self.synchronDisconnect = FALSE;
}

- (void)send:(MQTTMessage*)msg {
    if ([self.encoder status] == MQTTEncoderStatusReady) {
        [self.encoder encodeMessage:msg];
    }
    else {
        [self.queue addObject:msg];
        if ([self.delegate respondsToSelector:@selector(buffered:queued:flowingIn:flowingOut:)]) {
            [self.delegate buffered:self
                             queued:[self.queue count]
                          flowingIn:[self.rxFlows count]
                         flowingOut:[self.txFlows count]];
        }
    }
}

- (UInt16)nextMsgId {
    self.txMsgId++;
    while (self.txMsgId == 0 || (self.txFlows)[[NSNumber numberWithUnsignedInt:self.txMsgId]] != nil) {
        self.txMsgId++;
    }
    return self.txMsgId;
}

- (void)webSocket:(SRWebSocket *)webSocket didReceiveMessage:(id)message{
    [self.decoder decodeMessage:message];
}

- (void)webSocketDidOpen:(SRWebSocket *)webSocket{
    NSLog(@"connected to websocket");
    self.synchronWSConnect = FALSE;
}

- (void)webSocket:(SRWebSocket *)webSocket didFailWithError:(NSError *)error{
    NSLog(@"Failed to connect : %@",[error debugDescription]);
    self.synchronWSConnect = FALSE;
    [self connectionError:error];
}

- (void)webSocket:(SRWebSocket *)webSocket didCloseWithCode:(NSInteger)code reason:(NSString *)reason wasClean:(BOOL)wasClean{
    NSLog(@"ConnectionClosed : %@",reason);
    self.synchronWSConnect = FALSE;
    [self error:MQTTSessionEventConnectionClosedByBroker error:nil];
}

- (void)webSocket:(SRWebSocket *)webSocket didReceivePong:(NSData *)pongPayload{
    
}

@end
